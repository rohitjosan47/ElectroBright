#pragma once
// The first-boot check of a freshly updated firmware (rollback).
//
// A new image starts in the bootloader's pending-verify state. It confirms
// itself only when everything a working light needs is up within
// kDeadlineMs:
//  * NVS readable, and a write read back (kProbeKey);
//  * the fixture type loaded;
//  * the render loop running;
//  * BLE advertising (or already connected), with the command service
//    registered and advertised;
//  * the update receiver ready: the update service registered and a spare
//    slot of the right size (updateSlotBytes), so the next update can install.
// Otherwise it marks itself invalid and restarts, and the bootloader returns
// to the previous firmware; a crash or a task-watchdog reset before the
// confirmation has the same effect.
//
// While it is unconfirmed the light refuses SET_TYPE, FACTORY_RESET and an
// update BEGIN as busy.

#include <stddef.h>
#include <stdint.h>

#include "../state/KeyValueStore.h"

namespace selfcheck {

constexpr uint32_t kDeadlineMs = 15000;
constexpr uint32_t kMinRenderFrames = 400;  // 2 s of 200 Hz frames
constexpr uint32_t kNvsRetryMs = 1000;      // a failed write-and-read-back is retried this often

// The key of the write-and-read-back, in the system namespace (cfg::kSystemNvsNamespace).
constexpr const char* kProbeKey = "chk";

struct Inputs {
  bool nvsReadable;
  bool typeLoaded;  // the stored fixture type (if any) was read and resolved
  uint32_t renderFrames;
  bool bleUp;           // advertising or connected
  bool nvsRoundTrip;    // a write of kProbeKey read back the same value
  bool commandService;  // the command (UART) service is registered and advertised
  bool otaReady;        // the update service is registered and updateSlotBytes() > 0
};

enum class Verdict : uint8_t { Pending, Pass, Fail };

// Rollback test images (cfg::kRollbackTest) never pass: FailCheck fails at the
// deadline like a broken image; Freeze stops the control task kFreezeAfterMs
// after boot (freezeNow), so the task watchdog restarts the chip unconfirmed.
enum class TestImage : uint8_t { None = 0, FailCheck = 1, Freeze = 2 };
constexpr uint32_t kFreezeAfterMs = 3000;

inline Verdict evaluate(const Inputs& in, uint32_t sinceBootMs, TestImage test = TestImage::None) {
  if (test == TestImage::None && in.nvsReadable && in.typeLoaded && in.renderFrames >= kMinRenderFrames && in.bleUp &&
      in.nvsRoundTrip && in.commandService && in.otaReady) {
    return Verdict::Pass;
  }
  return sinceBootMs >= kDeadlineMs ? Verdict::Fail : Verdict::Pending;
}

// The Freeze test image stops here (only while it is unconfirmed).
inline bool freezeNow(TestImage test, uint32_t sinceBootMs) {
  return test == TestImage::Freeze && sinceBootMs >= kFreezeAfterMs;
}

// Writes `value` under kProbeKey and reads it back.
inline bool nvsRoundTrip(IKeyValueStore& kv, uint32_t value) {
  uint32_t back = ~value;
  return kv.write(kProbeKey, &value, sizeof(value)) && kv.read(kProbeKey, &back, sizeof(back)) && back == value;
}

// The update capacity the light announces (CAPS OTA=): the spare slot's size
// when there is one that holds at least what the running slot holds, else 0
// (no second slot, or one too small for this firmware's successors).
constexpr uint32_t updateSlotBytes(size_t spareBytes, size_t runningBytes) {
  return spareBytes > 0 && runningBytes > 0 && spareBytes >= runningBytes ? static_cast<uint32_t>(spareBytes) : 0;
}

}  // namespace selfcheck
