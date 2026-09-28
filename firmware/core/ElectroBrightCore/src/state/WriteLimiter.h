#pragma once
// The budget of NVS commits: attempts at least cfg::kStorageMinIntervalMs
// apart, and at most cfg::kStorageMaxPerMinute commits in any minute (a
// failed attempt wears nothing, so it counts for the interval only).
// StateStore holds and coalesces whatever does not fit and commits it later,
// so the last value always lands. Portable; no locking (control task only).

#include <stdint.h>

#include "../config/Config.h"

class WriteLimiter {
 public:
  static constexpr uint32_t kWindowMs = 60000;

  bool allowed(uint32_t nowMs) const {
    if (attempted_ && static_cast<uint32_t>(nowMs - lastMs_) < cfg::kStorageMinIntervalMs) return false;
    // The oldest of the last kCap commits must have left the window.
    return count_ < kCap || static_cast<uint32_t>(nowMs - times_[head_]) >= kWindowMs;
  }

  void note(uint32_t nowMs, bool committed) {
    attempted_ = true;
    lastMs_ = nowMs;
    if (!committed) return;
    times_[head_] = nowMs;
    head_ = static_cast<uint8_t>((head_ + 1) % kCap);
    if (count_ < kCap) ++count_;
  }

 private:
  static constexpr uint8_t kCap = cfg::kStorageMaxPerMinute;
  static_assert(kCap > 0, "at least one commit a minute");

  uint32_t times_[kCap] = {};  // the last kCap commits
  uint8_t head_ = 0;           // the next slot to fill; once full, the oldest entry
  uint8_t count_ = 0;
  bool attempted_ = false;
  uint32_t lastMs_ = 0;        // the last attempt
};
