#include "DeviceState.h"

#include <string.h>

namespace state {

Scene defaultScene() {
  Scene s;
  memset(&s, 0, sizeof(s));
  s.color = {255, 255, 255, 0};
  s.brightness = 255;
  s.mode = 1;
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) {
    s.speed[i] = 5;
    s.freq[i] = 5;
  }
  s.fireworkColorMode = 0;
  s.clubColorMode = 0;
  s.policeColorMode = 1;
  s.policeA = {255, 165, 0, 0};  // matches the app's defaults
  s.policeB = {0, 0, 0, 255};
  return s;
}

Settings defaultSettings() {
  Settings s;
  memset(&s, 0, sizeof(s));
  s.soundEnabled = 1;
  return s;
}

bool isValid(const Scene& s) {
  if (s.mode < 1 || s.mode > cfg::kNumModes) return false;
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) {
    if (s.speed[i] < cfg::kMinLevel || s.speed[i] > cfg::kMaxLevel) return false;
    if (s.freq[i] < cfg::kMinLevel || s.freq[i] > cfg::kMaxLevel) return false;
  }
  return s.fireworkColorMode <= 1 && s.clubColorMode <= 1 && s.policeColorMode <= 1;
}

bool isValid(const Settings& s) { return s.soundEnabled <= 1; }

uint8_t colorModeFor(const Scene& s, uint8_t mode) {
  switch (mode) {
    case 4: return s.fireworkColorMode;
    case 9: return s.clubColorMode;
    case 12: return s.policeColorMode;
    default: return 0;
  }
}

}  // namespace state
