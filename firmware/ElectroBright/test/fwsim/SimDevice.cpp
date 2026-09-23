#include "SimDevice.h"

#include <string.h>

#include "../../src/config/Config.h"
#include "../../src/protocol/BinaryFrame.h"

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
}

// ---- Lifecycle ------------------------------------------------------------------
SimDevice::SimDevice() : rig_(std::make_unique<Rig>(*this, kv_)) {}

void SimDevice::boot() { rig_->core.begin(now_); }

void SimDevice::reboot() {
  rig_ = std::make_unique<Rig>(*this, kv_);
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
  delivered_.clear();
  now_ += 1500;  // boot time
  boot();
}

// ---- Radio (BleNus.cpp) -----------------------------------------------------------
void SimDevice::connect() {
  mtu_ = 23;
  connected_ = true;
  subscribed_ = false;
  events_.push_back(kConnected);
}

void SimDevice::disconnect() {
  connected_ = false;
  subscribed_ = false;
  events_.push_back(kDisconnected);
}

void SimDevice::write(const uint8_t* data, size_t len) {
  if (len == 0) return;
  if (binframe::isCandidate(data, len)) {
    ColorFrame frame{};
    if (binframe::decode(data, len, frame)) {
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
  } else {
    egress_.clear();
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

std::vector<SoundId> SimDevice::takeSounds() {
  std::vector<SoundId> out;
  out.swap(rig_->env.sounds);
  return out;
}
