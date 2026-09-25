#pragma once
// Single source of truth for what each mode exposes. MODE_CAPABILITIES is
// generated from this table, and the app's copy must match it:
// app/lib/core/protocol/eb/mode_catalog.dart (checked by
// app/test/cross_repo/mode_registry_sync_test.dart).

#include <stdint.h>

#include "../config/Config.h"

struct ModeInfo {
  uint8_t id;
  const char* name;
  bool hasSpeed;
  bool hasFrequency;
  bool hasColorMode;
  const char* speedLabel;      // UI name of the SPEED slider (what it really does)
  const char* frequencyLabel;  // UI name of the FREQUENCY slider
};

// clang-format off
constexpr ModeInfo kModes[cfg::kNumModes] = {
  { 1, "Solid Color",    false, false, false, nullptr,         nullptr},
  { 2, "Blink",          false, true,  false, nullptr,         "Blink Rate"},
  { 3, "Breath",         true,  true,  false, "Breath Shape",  "Breathing Rate"},
  { 4, "Fireworks",      true,  true,  true,  "Burst Speed",   "Launch Rate"},
  { 5, "TV Simulator",   true,  true,  false, "Scene Pace",    "Cuts & Flicker"},
  { 6, "Thunderstorm",   true,  true,  false, "Stroke Tempo",  "Strike Rate"},
  { 7, "Faulty Bulb",    true,  true,  false, "Glitch Speed",  "Glitch Rate"},
  { 8, "Welding",        true,  true,  false, "Weld Length",   "Weld Gap"},
  { 9, "Club Lights",    true,  true,  true,  "Tempo",         "Energy"},
  {10, "Rainbow",        false, true,  false, nullptr,         "Cycle Speed"},
  {11, "Fire",           true,  true,  false, "Flicker Speed", "Flame Intensity"},
  {12, "Police Strobe",  true,  true,  true,  "Flash Speed",   "Flashes per Side"},
  {13, "Candle",         true,  true,  false, "Flicker Speed", "Flicker Depth"},
};
// clang-format on

inline const ModeInfo& modeInfo(uint8_t mode) {
  if (mode < 1 || mode > cfg::kNumModes) mode = 1;
  return kModes[mode - 1];
}
