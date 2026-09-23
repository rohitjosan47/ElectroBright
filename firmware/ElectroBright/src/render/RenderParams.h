#pragma once
// Snapshot published by the control task and consumed by the render task
// every frame (through a SeqLock). Contains *targets*; the renderer smooths.

#include <stdint.h>

#include "../state/DeviceState.h"

struct RenderParams {
  Scene scene;
  uint8_t sleeping;   // 1 = fade to black and stay dark
  uint16_t fadeMs;    // duration of the sleep / wake fade triggered by this snapshot
};
