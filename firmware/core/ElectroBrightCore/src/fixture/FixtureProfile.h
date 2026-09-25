#pragma once
// Everything that makes one fixture differ from another: identity, channel
// layout, wiring and scene defaults. Each fixture sketch
// (firmware/fixtures/<Name>/Fixture.h) defines one and passes it to
// App::start(); the core itself holds no fixture-specific values.

#include <stdint.h>

#include "../core/Types.h"
#include "ChannelLayout.h"

// Bumped whenever FixtureProfile or App::start() change shape; every Fixture.h
// static_asserts the value it was written for, so a stale core copy in the
// Arduino IDE fails loudly instead of misbehaving.
constexpr int kCoreApi = 3;

struct SceneDefaults {
  Color8 color;    // power-up / factory-reset colour
  Color8 policeA;  // police strobe colours (manual colour mode)
  Color8 policeB;
};

struct FixtureProfile {
  const ChannelLayout* layout;
  const char* modelId;       // INFO reply: EB-C3-<LAYOUT>-V<n>
  const char* deviceName;    // BLE name; the app scans for the "ElectroBright_C3_" prefix
  const char* capsReply;     // complete CAPS reply line: ...,PRESETS=<cfg::kNumPresets>,LAYOUT=<layout name>[,MODES=<hex>]
  const char* nvsNamespace;  // settings + presets (max 15 chars, unique per fixture)
  uint8_t pins[kMaxChannels];  // GPIO for each layout channel, in wire order
  uint8_t buzzerPin;
  uint8_t parkLowPins[4];      // unused board outputs held low (e.g. unfitted MOSFET positions)
  uint8_t parkLowCount;
  SceneDefaults defaults;      // must fit the layout (absent channels 0)
  LinColor whiteMix;           // linear RGB that renders white-channel light on layouts without W
  bool legacyFrames;           // also accept the pre-3.x 7- and 6-byte RGBW binary frames
};
