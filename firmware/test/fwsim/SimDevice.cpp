#include "SimDevice.h"

#include <string.h>

#include "config/Config.h"
#include "ota/ImageIdentity.h"
#include "ota/SelfCheck.h"
#include "ota/UpdateRecord.h"
#include "protocol/BinaryFrame.h"

namespace {
constexpr uint8_t kConnected = 1;     // BleEvent::Connected
constexpr uint8_t kDisconnected = 2;  // BleEvent::Disconnected
}  // namespace

// ---- DeviceEnv (App.cpp) ----------------------------------------------------------
void SimDevice::Env::sendLine(const char* line) {
  if (!dev_.egress_.push(line)) Stats::inc(dev_.rig_->stats.egressDrops);
}

void SimDevice::Env::systemDiag(SystemDiag& d) {
  d.minFreeHeap = 180000;
  d.controlStackFree = 3000;
  d.renderStackFree = 2000;
  d.resetReason = 1;  // ESP_RST_POWERON
  d.uptimeSec = dev_.now_ / 1000;
  d.runningSlot = static_cast<uint32_t>(dev_.otaFlash_.running);
  d.rolledBack = dev_.otaFlash_.rolledBack() ? 1 : 0;
  d.pendingVerify = dev_.otaFlash_.pendingVerify() ? 1 : 0;
  d.finishMs = dev_.lastFinishMs_;
}

// ---- OtaEnv (App.cpp) ------------------------------------------------------------------
void SimDevice::OtaEnv::otaActive(bool active) {
  dev_.rig_->core.setOtaBusy(active);
  dev_.fastLink_ = active && dev_.connected_;  // ble::setUpdateLink
}

void SimDevice::OtaEnv::otaRestart(uint32_t finishMs) {
  fxselect::rememberForUpdate(dev_.system_, dev_.fixture().type);
  updaterecord::writeFinishMs(dev_.system_, finishMs);
  dev_.rig_->env.restart();
}

FirmwareVersion SimDevice::Rig::runningVersion() {
  FirmwareVersion v{};
  imageid::parseVersion(imageid::running().version, v);
  return v;
}

// ---- Lifecycle ------------------------------------------------------------------
SimDevice::SimDevice(FixtureType buildDefault)
    : buildDefault_(buildDefault), rig_(std::make_unique<Rig>(*this, kv_, system_, buildDefault)) {}

void SimDevice::boot() {
  selfChecking_ = otaFlash_.pendingVerify();
  updateSlotBytes_ = selfcheck::updateSlotBytes(otaFlash_.spareSize(), otaFlash_.runningSize());
  lastFinishMs_ = updaterecord::readFinishMs(system_);
  nvsRoundTrip_ = false;
  nvsTried_ = false;
  rig_->core.setPendingVerify(selfChecking_);
  rig_->core.setUpdateSlotBytes(updateSlotBytes_);
  rig_->core.begin(now_);
  bootMs_ = now_;
}

void SimDevice::reboot() {
  delivered_.clear();
  otaDelivered_.clear();
  restartNow();
}

// esp_restart(): like a power cycle, except that notifications already
// delivered to the phone stay delivered.
void SimDevice::restartNow() {
  otaFlash_.bootloader();
  rig_ = std::make_unique<Rig>(*this, kv_, system_, buildDefault_);
  otaControl_.clear();
  otaData_.clear();
  otaDataBytes_ = 0;
  otaReplies_.clear();
  otaSubscribed_ = false;
  fastLink_ = false;
  egress_.clear();
  assembler_ = LineAssembler();
  seen_ = {};
  rxText_.clear();
  mailboxFull_ = false;
  events_.clear();
  connected_ = false;
  subscribed_ = false;
  mtu_ = 23;
  notifyFailures_ = 0;
  now_ += 1500;  // boot time
  boot();
}

// ---- Radio (BleNus.cpp) -----------------------------------------------------------
void SimDevice::connect() {
  mtu_ = 23;
  connected_ = true;
  subscribed_ = false;
  otaSubscribed_ = false;
  events_.push_back(kConnected);
}

void SimDevice::disconnect() {
  connected_ = false;
  subscribed_ = false;
  otaSubscribed_ = false;
  fastLink_ = false;  // a new link starts with the normal parameters
  events_.push_back(kDisconnected);
}

void SimDevice::write(const uint8_t* data, size_t len) {
  if (len == 0) return;
  const ChannelLayout& layout = *fixture().layout;
  if (binframe::isCandidate(data, len, layout)) {
    ColorFrame frame{};
    if (binframe::decode(data, len, layout, fixture().legacyFrames, frame)) {
      mailbox_ = frame;  // xQueueOverwrite: only the newest colour matters
      mailboxFull_ = true;
      Stats::inc(rig_->stats.binaryOk);
    } else {
      Stats::inc(rig_->stats.binaryBad);
    }
  } else if (cfg::kRxStreamBytes - rxText_.size() >= len) {
    rxText_.insert(rxText_.end(), data, data + len);  // all-or-nothing
  } else {
    Stats::inc(rig_->stats.rxStreamDrops);
  }
}

void SimDevice::otaControl(const uint8_t* data, size_t len) {
  if (otaControl_.size() >= 4) return;  // xQueueSend(…, 0) on a full queue
  // OtaControlMsg: longer writes arrive as an empty (malformed) request.
  if (len > 48) len = 0;
  otaControl_.emplace_back(data, data + len);
}

void SimDevice::otaData(const uint8_t* data, size_t len) {
  if (len == 0 || len > cfg::kOtaMaxWrite) return;
  // xMessageBufferSend: each message also stores its length (4 bytes).
  if (otaDataBytes_ + len + 4 > cfg::kOtaDataBufferBytes) return;
  otaData_.emplace_back(data, data + len);
  otaDataBytes_ += len + 4;
}

bool SimDevice::notify(const uint8_t* data, size_t len) {
  if (!connected_) return false;
  if (notifyFailures_ > 0) {
    --notifyFailures_;
    return false;  // out of buffers: Egress keeps the data and retries
  }
  // NimBLE sends even when the phone has not subscribed; the bytes are lost.
  if (subscribed_) delivered_.emplace_back(data, data + len);
  return true;
}

// ---- Control task (App.cpp controlTask) ----------------------------------------------
void SimDevice::passBegin() {
  // 1. Connection lifecycle.
  while (!events_.empty()) {
    const uint8_t ev = events_.front();
    events_.pop_front();
    egress_.clear();  // never deliver a previous session's replies
    assembler_.reset();
    if (ev == kConnected) {
      rig_->core.onConnect(now_);
    } else {
      rig_->core.onDisconnect(now_);
    }
  }
  // 2. Latest binary colour.
  if (mailboxFull_) {
    mailboxFull_ = false;
    rig_->core.onColorFrame(mailbox_, now_);
  }
}

void SimDevice::passEnd() {
  // 3. Text commands, executed in batches.
  static char lines[cfg::kMaxLinesPerBatch][cfg::kMaxLineLength + 1];
  const char* linePtrs[cfg::kMaxLinesPerBatch];
  size_t count = 0;
  auto flushBatch = [&]() {
    if (count > 0) {
      rig_->core.processLines(linePtrs, count, now_);
      count = 0;
    }
  };
  uint8_t chunk[128];
  while (!rxText_.empty()) {
    size_t got = 0;
    while (got < sizeof(chunk) && !rxText_.empty()) {
      chunk[got++] = rxText_.front();
      rxText_.pop_front();
    }
    assembler_.feed(chunk, got, [&](const char* line, size_t len) {
      memcpy(lines[count], line, len + 1);
      linePtrs[count] = lines[count];
      if (++count == cfg::kMaxLinesPerBatch) flushBatch();
    });
  }
  flushBatch();

  // 3b. Wireless update: requests, then data.
  rig_->ota.setBlocked(rig_->core.restartPending() || selfChecking_);
  while (!otaControl_.empty()) {
    const std::vector<uint8_t> m = otaControl_.front();
    otaControl_.pop_front();
    rig_->ota.onControl(m.data(), m.size(), now_);
  }
  while (!otaData_.empty()) {
    const std::vector<uint8_t> m = otaData_.front();
    otaData_.pop_front();
    otaDataBytes_ -= m.size() + 4;
    rig_->ota.onData(m.data(), m.size(), now_);
  }
  rig_->ota.tick(now_);

  const LineAssembler::Counters& c = assembler_.counters();
  Stats::inc(rig_->stats.rxLineOverflows, c.overflows - seen_.overflows);
  Stats::inc(rig_->stats.rxRejectedBytes, c.rejected - seen_.rejected);
  seen_ = c;

  // 4. Timer expiry + persistence.
  rig_->core.tick(now_);

  // 5. Replies.
  if (connected_) {
    const uint32_t retriesBefore = egress_.retries();
    egress_.flush(maxPayload(), [this](const uint8_t* d, size_t n) { return notify(d, n); });
    Stats::inc(rig_->stats.notifyRetries, egress_.retries() - retriesBefore);
    otaReplies_.flush([this](const uint8_t* d, size_t n) {
      if (otaSubscribed_) otaDelivered_.emplace_back(d, d + n);  // ble::otaNotify
      return true;
    });
  } else {
    egress_.clear();
    otaReplies_.clear();
  }

  // 6. SET_TYPE / update: restart once the reply has gone out (the device
  // also waits cfg::kRestartDelayMs; virtual time needs no wait).
  if (rig_->env.restartRequested && ((egress_.pending() == 0 && otaReplies_.empty()) || !connected_)) {
    rig_->core.flushStorage();
    ++restarts_;
    restartNow();
    return;
  }
  selfCheck();
}

void SimDevice::selfCheck() {
  if (!selfChecking_) return;
  // The render task runs 200 frames a second from boot.
  const uint32_t since = now_ - bootMs_;
  if (!nvsRoundTrip_ && (!nvsTried_ || now_ - nvsTriedMs_ >= selfcheck::kNvsRetryMs)) {
    nvsTried_ = true;
    nvsTriedMs_ = now_;
    nvsRoundTrip_ = selfcheck::nvsRoundTrip(system_, now_);
  }
  const selfcheck::Inputs in{true,           fxselect::typeLoaded(system_, fixture().type),
                             since / 5u,     true,
                             nvsRoundTrip_,  commandService_,
                             updateService_ && updateSlotBytes_ > 0};
  switch (selfcheck::evaluate(in, since)) {
    case selfcheck::Verdict::Pending:
      return;
    case selfcheck::Verdict::Pass:
      selfChecking_ = false;
      rig_->core.setPendingVerify(false);
      otaFlash_.confirm();
      fxselect::forgetUpdate(system_);
      return;
    case selfcheck::Verdict::Fail:
      otaFlash_.markInvalid();  // esp_ota_mark_app_invalid_rollback_and_reboot
      ++restarts_;
      restartNow();
      return;
  }
}

void SimDevice::advance(uint32_t ms) {
  while (ms > 0) {
    const uint32_t step = ms < cfg::kControlWakeMs ? ms : cfg::kControlWakeMs;
    now_ += step;
    ms -= step;
    pass();
  }
}

std::vector<std::vector<uint8_t>> SimDevice::takeNotifications() {
  std::vector<std::vector<uint8_t>> out;
  out.swap(delivered_);
  return out;
}

std::vector<std::vector<uint8_t>> SimDevice::takeOtaNotifications() {
  std::vector<std::vector<uint8_t>> out;
  out.swap(otaDelivered_);
  return out;
}

std::vector<SoundId> SimDevice::takeSounds() {
  std::vector<SoundId> out;
  out.swap(rig_->env.sounds);
  return out;
}
