#pragma once
// The first-boot check of a freshly updated firmware (rollback).
//
// A new image starts in the bootloader's pending-verify state. It confirms
// itself only when everything a working light needs is up within
// kDeadlineMs: NVS readable, the fixture type loaded, the render loop running
// and BLE advertising (or already connected). Otherwise it marks itself invalid
// and restarts, and the bootloader returns to the previous firmware; a crash
// or a task-watchdog reset before the confirmation has the same effect.

#include <stdint.h>

namespace selfcheck {

constexpr uint32_t kDeadlineMs = 15000;
constexpr uint32_t kMinRenderFrames = 400;  // 2 s of 200 Hz frames

struct Inputs {
  bool nvsReadable;
  bool typeLoaded;  // the stored fixture type (if any) was read and resolved
  uint32_t renderFrames;
  bool bleUp;       // advertising or connected
};

enum class Verdict : uint8_t { Pending, Pass, Fail };

// Rollback test images (cfg::kRollbackTest) never pass: FailCheck fails at the
// deadline like a broken image; Freeze stops the control task kFreezeAfterMs
// after boot (freezeNow), so the task watchdog restarts the chip unconfirmed.
enum class TestImage : uint8_t { None = 0, FailCheck = 1, Freeze = 2 };
constexpr uint32_t kFreezeAfterMs = 3000;

inline Verdict evaluate(const Inputs& in, uint32_t sinceBootMs, TestImage test = TestImage::None) {
  if (test == TestImage::None && in.nvsReadable && in.typeLoaded && in.renderFrames >= kMinRenderFrames && in.bleUp) {
    return Verdict::Pass;
  }
  return sinceBootMs >= kDeadlineMs ? Verdict::Fail : Verdict::Pending;
}

// The Freeze test image stops here (only while it is unconfirmed).
inline bool freezeNow(TestImage test, uint32_t sinceBootMs) {
  return test == TestImage::Freeze && sinceBootMs >= kFreezeAfterMs;
}

}  // namespace selfcheck
