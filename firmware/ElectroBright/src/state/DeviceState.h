#pragma once
// The device's persistent model.
//
//   Scene    — everything a preset captures (colour, mode, per-mode sliders…)
//   Settings — device-level preferences that presets must NOT change (mute)
//
// Both are plain byte structs (no padding) so they can be stored as NVS blobs
// directly; every field is range-validated on load.

#include <stdint.h>

#include "../config/Config.h"
#include "../core/Types.h"

struct Scene {
  Rgbw8 color;
  uint8_t brightness;
  uint8_t mode;  // 1..13
  uint8_t speed[cfg::kNumModes];
  uint8_t freq[cfg::kNumModes];
  uint8_t fireworkColorMode;  // 0 = manual (base colour), 1 = auto palette
  uint8_t clubColorMode;      // 0 = manual, 1 = auto
  uint8_t policeColorMode;    // 0 = manual (colours A/B), 1 = auto red/blue
  Rgbw8 policeA;
  Rgbw8 policeB;
};
static_assert(sizeof(Scene) == 4 + 1 + 1 + 2 * cfg::kNumModes + 3 + 4 + 4, "Scene must be tightly packed");

struct Settings {
  uint8_t soundEnabled;
  uint8_t reserved[3];
};
static_assert(sizeof(Settings) == 4, "Settings must be tightly packed");

namespace state {

Scene defaultScene();
Settings defaultSettings();

// Strict validation of every field (used for anything read back from flash).
bool isValid(const Scene& s);
bool isValid(const Settings& s);

inline uint8_t activeSpeed(const Scene& s) { return s.speed[s.mode - 1]; }
inline uint8_t activeFreq(const Scene& s) { return s.freq[s.mode - 1]; }

// Colour-mode flag relevant to a mode (fireworks / club / police), else 0.
uint8_t colorModeFor(const Scene& s, uint8_t mode);

}  // namespace state
