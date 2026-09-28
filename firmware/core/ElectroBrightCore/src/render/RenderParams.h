#pragma once
// Snapshot published by the control task and consumed by the render task
// every frame (through a SeqLock). Contains *targets*; the renderer smooths.

#include <stdint.h>

#include "../state/DeviceState.h"

struct RenderParams {
  Scene scene;
  uint8_t sleeping;   // 1 = fade to black and stay dark
  uint16_t fadeMs;    // duration of the sleep / wake fade triggered by this snapshot
  uint16_t identifyId;  // non-zero: IDENTIFY flashes (a new id restarts them); 0 cancels
  // PROBE: 0 = off, else physical output + 1 (board::kOutputPins). While on,
  // that one output runs at cfg::kProbeDuty and every other LED output is off.
  uint8_t probe;
};
