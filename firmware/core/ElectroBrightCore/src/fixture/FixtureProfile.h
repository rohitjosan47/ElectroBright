#pragma once
// Everything that makes one fixture type differ from another: identity,
// channel layout, wiring and scene defaults. One firmware image holds every
// type (fixture/Profiles.h); the light's active type is stored in NVS and
// chosen at boot (fixture/FixtureType.h).

#include <stdint.h>

#include "../core/Types.h"
#include "ChannelLayout.h"

// Bumped whenever FixtureProfile or App::start() change shape; every sketch
// static_asserts the value it was written for, so a stale core copy in the
// Arduino IDE fails loudly instead of misbehaving.
constexpr int kCoreApi = 4;

// Fixture types. The values are stored in NVS ("fx"): never renumber.
enum class FixtureType : uint8_t { None = 0, Rgbw = 1, Rgb = 2, Rgbcct = 3, Cct = 4, W = 5 };

struct SceneDefaults {
  Color8 color;    // power-up / factory-reset colour
  Color8 policeA;  // police strobe colours (manual colour mode)
  Color8 policeB;
};

struct FixtureProfile {
  FixtureType type;
  const ChannelLayout* layout;  // also the CAPS LAYOUT= value and its MODES= mask
  const char* modelId;       // INFO reply: EB-C3-<LAYOUT>-V<n>
  const char* deviceName;    // BLE name; the app scans for the "ElectroBright_C3_" prefix
  uint8_t pins[kMaxChannels];  // GPIO for each layout channel, in wire order
  uint8_t buzzerPin;
  uint8_t parkLowPins[5];      // board outputs this type does not use: held low
  uint8_t parkLowCount;
  SceneDefaults defaults;      // must fit the layout (absent channels 0)
  LinColor whiteMix;           // linear RGB that renders white-channel light on layouts without W
  bool legacyFrames;           // also accept the pre-3.x 7- and 6-byte RGBW binary frames
};
