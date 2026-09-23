#include "Replies.h"

#include <stdio.h>

#include "../render/ModeRegistry.h"

namespace {
size_t clampLen(int n, size_t cap) {
  if (n < 0) return 0;
  const size_t len = static_cast<size_t>(n);
  return len >= cap ? (cap > 0 ? cap - 1 : 0) : len;
}
}  // namespace

namespace replies {

size_t status(char* out, size_t cap, const StatusView& v) {
  const Scene& s = *v.scene;
  const int n = snprintf(out, cap,
                         "STATUS:%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%lu,%u,%u,%u,%u,%u,%u,%u,%u,%u",
                         s.color.r, s.color.g, s.color.b, s.color.w, s.brightness, s.mode,
                         state::activeSpeed(s), state::activeFreq(s), s.fireworkColorMode, s.clubColorMode,
                         s.policeColorMode, v.sleeping ? 1u : 0u, v.timerActive ? 1u : 0u,
                         static_cast<unsigned long>(v.timerRemainingSec), v.soundEnabled ? 1u : 0u, s.policeA.r,
                         s.policeA.g, s.policeA.b, s.policeA.w, s.policeB.r, s.policeB.g, s.policeB.b, s.policeB.w);
  return clampLen(n, cap);
}

size_t modeSettings(char* out, size_t cap, const Scene& s) {
  size_t len = clampLen(snprintf(out, cap, "MODE_SETTINGS:"), cap);
  for (uint8_t i = 0; i < cfg::kNumModes && len + 1 < cap; ++i) {
    len += clampLen(snprintf(out + len, cap - len, i + 1 < cfg::kNumModes ? "%u,%u;" : "%u,%u", s.speed[i], s.freq[i]),
                    cap - len);
  }
  return len;
}

size_t presets(char* out, size_t cap, uint32_t mask) {
  size_t len = clampLen(snprintf(out, cap, "PRESETS:"), cap);
  for (uint8_t i = 0; i < cfg::kNumPresets && len + 1 < cap; ++i) {
    if (mask & (1u << i)) len += clampLen(snprintf(out + len, cap - len, "%u,", i), cap - len);
  }
  return len;
}

size_t capabilities(char* out, size_t cap, uint8_t mode) {
  const ModeInfo& m = modeInfo(mode);
  if (!m.hasSpeed && !m.hasFrequency) return clampLen(snprintf(out, cap, "CAPABILITIES:NONE"), cap);
  return clampLen(snprintf(out, cap, "CAPABILITIES:%s%s%s%s", m.hasSpeed ? "SPEED" : "",
                           (m.hasSpeed && m.hasFrequency) ? "," : "", m.hasFrequency ? "FREQUENCY" : "",
                           m.hasColorMode ? ",COLOR_MODE" : ""),
                  cap);
}

size_t error(char* out, size_t cap, const char* code) {
  return clampLen(snprintf(out, cap, "ERROR:%s", code ? code : "UNKNOWN"), cap);
}

size_t presetEmpty(char* out, size_t cap, uint8_t id) {
  return clampLen(snprintf(out, cap, "ERROR:PRESET_EMPTY:%u", id), cap);
}

}  // namespace replies
