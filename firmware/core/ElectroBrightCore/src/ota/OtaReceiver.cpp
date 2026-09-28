#include "OtaReceiver.h"

#include <string.h>

namespace {

uint32_t readU32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
uint16_t readU16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
void writeU32(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v);
  p[1] = static_cast<uint8_t>(v >> 8);
  p[2] = static_cast<uint8_t>(v >> 16);
  p[3] = static_cast<uint8_t>(v >> 24);
}

}  // namespace

bool OtaReceiver::Image::same(const Image& o) const {
  return size == o.size && memcmp(hash, o.hash, sizeof(hash)) == 0 && imageid::compare(version, o.version) == 0;
}

// ------------------------------------------------------------------ ingress
void OtaReceiver::onControl(const uint8_t* d, size_t len, uint32_t nowMs) {
  if (len == 0) return replyError(ota::Error::BadRequest);
  // Nothing changes until the verification is done.
  if (finishing_ && (d[0] == ota::kBegin || d[0] == ota::kEnd || d[0] == ota::kAbort)) {
    return replyError(ota::Error::Busy);
  }
  switch (d[0]) {
    case ota::kBegin:
      return begin(d, len, nowMs);
    case ota::kEnd:
      if (len != 1) return replyError(ota::Error::BadRequest);
      return end(nowMs);
    case ota::kAbort:
      if (len != 1) return replyError(ota::Error::BadRequest);
      return abortTransfer();
    case ota::kStatus:
      if (len != 1) return replyError(ota::Error::BadRequest);
      return replyState();
    default:
      return replyError(ota::Error::BadRequest);
  }
}

void OtaReceiver::onData(const uint8_t* d, size_t len, uint32_t nowMs) {
  if (!active_ || finishing_ || len <= ota::kDataHeader) {
    ++ignored_;
    return;
  }
  lastDataMs_ = nowMs;
  const uint32_t offset = readU32(d);
  const uint8_t* payload = d + ota::kDataHeader;
  const uint32_t n = static_cast<uint32_t>(len - ota::kDataHeader);
  if (offset != next_) {
    // A duplicate or a gap: ignored; one ACK tells the app where to go on.
    ++ignored_;
    if (!outOfOrderReported_) {
      outOfOrderReported_ = true;
      replyAck();
    }
    return;
  }
  if (n > image_.size - next_) {
    replyError(ota::Error::BadSize);
    return stop(false);
  }
  if (!flash_.write(payload, n)) {
    replyError(ota::Error::FlashError);
    return stop(false);
  }
  sha_.update(payload, n);
  const uint32_t before = next_;
  next_ += n;
  outOfOrderReported_ = false;
  if (next_ / ota::kWindow != before / ota::kWindow || next_ == image_.size) replyAck();
}

void OtaReceiver::tick(uint32_t nowMs) {
  if (finishing_) return pollFinish(nowMs);
  if (!active_ || static_cast<uint32_t>(nowMs - lastDataMs_) < ota::kTimeoutMs) return;
  // Stopped, but what arrived stays usable for a BEGIN of the same image.
  stop(true);
  replyError(ota::Error::Timeout);
}

// ------------------------------------------------------------------ requests
void OtaReceiver::begin(const uint8_t* d, size_t len, uint32_t nowMs) {
  if (len != ota::kBeginLength) return replyError(ota::Error::BadRequest);
  Image img;
  img.size = readU32(d + 1);
  memcpy(img.hash, d + 5, sizeof(img.hash));
  img.version = {readU16(d + 37), readU16(d + 39), readU16(d + 41)};
  const bool reinstall = (d[43] & ota::kFlagReinstall) != 0;

  if (restarting_ || blocked_) return replyError(ota::Error::Busy);
  if (active_) {
    // The app lost the link and came back: the same image goes on.
    if (!img.same(image_)) return replyError(ota::Error::Busy);
    lastDataMs_ = nowMs;
    outOfOrderReported_ = false;
    uint8_t r[7] = {ota::kBeginOk};
    writeU32(r + 1, next_);
    r[5] = static_cast<uint8_t>(ota::kWindow);
    r[6] = static_cast<uint8_t>(ota::kWindow >> 8);
    return env_.otaReply(r, sizeof(r));
  }
  if (img.size == 0 || img.size > flash_.spareSize()) return replyError(ota::Error::BadSize);
  const int order = imageid::compare(img.version, running_);
  if (order < 0) return replyError(ota::Error::Downgrade);
  if (order == 0 && !reinstall) return replyError(ota::Error::SameVersion);

  IOtaFlash::Status st;
  if (resume_.valid && resume_.image.same(img)) {
    st = flash_.resume(resume_.next);
    if (st == IOtaFlash::Status::Ok) {
      next_ = resume_.next;
      sha_ = resume_.sha;
    }
  } else {
    resume_.valid = false;
    st = flash_.begin();
    next_ = 0;
    sha_.reset();
  }
  if (st == IOtaFlash::Status::Busy) return replyError(ota::Error::Busy);
  if (st != IOtaFlash::Status::Ok) {
    resume_.valid = false;
    return replyError(ota::Error::FlashError);
  }
  image_ = img;
  resume_.valid = false;
  active_ = true;
  lastDataMs_ = nowMs;
  outOfOrderReported_ = false;
  env_.otaActive(true);
  uint8_t r[7] = {ota::kBeginOk};
  writeU32(r + 1, next_);
  r[5] = static_cast<uint8_t>(ota::kWindow);
  r[6] = static_cast<uint8_t>(ota::kWindow >> 8);
  env_.otaReply(r, sizeof(r));
}

void OtaReceiver::end(uint32_t nowMs) {
  if (!active_) return replyError(restarting_ ? ota::Error::Busy : ota::Error::BadRequest);
  if (next_ != image_.size) return replyError(ota::Error::Incomplete);  // still receiving
  uint8_t digest[Sha256::kDigestSize];
  sha_.digest(digest);
  if (memcmp(digest, image_.hash, sizeof(digest)) != 0) {
    replyError(ota::Error::HashMismatch);
    return stop(false);
  }
  if (flash_.startFinish() != IOtaFlash::Status::Ok) {
    replyError(ota::Error::FlashError);
    return stop(false);
  }
  finishing_ = true;
  endMs_ = nowMs;
  pollFinish(nowMs);  // a quick verification completes right here
}

void OtaReceiver::pollFinish(uint32_t nowMs) {
  const IOtaFlash::Status st = flash_.pollFinish();
  if (st == IOtaFlash::Status::Pending) return;
  finishing_ = false;
  if (st != IOtaFlash::Status::Ok) {
    replyError(st == IOtaFlash::Status::Invalid ? ota::Error::NotElectroBright : ota::Error::FlashError);
    return stop(false);
  }
  // The identity block, read back from the slot itself.
  uint8_t* head = head_;
  const size_t headLen = image_.size < sizeof(head_) ? image_.size : sizeof(head_);
  ImageIdentity id;
  FirmwareVersion v;
  if (!flash_.read(0, head, headLen)) {
    replyError(ota::Error::FlashError);
    return stop(false);
  }
  if (!imageid::find(head, headLen, id) || !imageid::isUniversal(id) || !imageid::parseVersion(id.version, v) ||
      imageid::compare(v, image_.version) != 0) {
    replyError(ota::Error::NotElectroBright);
    return stop(false);
  }
  if (!flash_.setBoot()) {
    replyError(ota::Error::FlashError);
    return stop(false);
  }
  active_ = false;
  restarting_ = true;
  const uint8_t r[1] = {ota::kEndOk};
  env_.otaReply(r, sizeof(r));
  env_.otaRestart(nowMs - endMs_);  // stays busy until the restart
}

void OtaReceiver::abortTransfer() {
  if (active_) {
    stop(false);
  } else {
    resume_.valid = false;
  }
  const uint8_t r[1] = {ota::kAborted};
  env_.otaReply(r, sizeof(r));
}

// ------------------------------------------------------------------ helpers
void OtaReceiver::stop(bool keepResume) {
  // A finished (esp_ota_end) write has nothing open; abort() is then a no-op.
  flash_.abort();
  if (keepResume && next_ > 0) {
    resume_.valid = true;
    resume_.image = image_;
    resume_.next = next_;
    resume_.sha = sha_;
  } else {
    resume_.valid = false;
  }
  active_ = false;
  env_.otaActive(false);
}

void OtaReceiver::replyError(ota::Error code) {
  uint8_t r[6] = {ota::kError, static_cast<uint8_t>(code)};
  writeU32(r + 2, active_ ? next_ : 0);
  env_.otaReply(r, sizeof(r));
}

void OtaReceiver::replyAck() {
  uint8_t r[5] = {ota::kAck};
  writeU32(r + 1, next_);
  env_.otaReply(r, sizeof(r));
}

void OtaReceiver::replyState() {
  uint8_t r[10] = {ota::kState};
  r[1] = restarting_ ? ota::kStateRestarting : active_ ? ota::kStateReceiving : ota::kStateIdle;
  writeU32(r + 2, active_ ? next_ : 0);
  writeU32(r + 6, active_ ? image_.size : 0);
  env_.otaReply(r, sizeof(r));
}
