#pragma once
// What a light shows during a wireless update: a slow, low breathing on its
// white LEDs (the RGB LEDs mixing white on RGB), every other output off. It is
// driven by the LEDC's hardware fade: the CPU only reverses the ramp every
// kRampMs, so flash writes (which stall the CPU) cannot make it stutter; a late
// reversal just holds the dimmest or brightest point a little longer.

#include <stdint.h>

#include "../fixture/FixtureProfile.h"

namespace otaglow {

constexpr uint32_t kRampMs = 2000;       // one way; a breath is 4 s
constexpr uint16_t kLowCounts = 4;       // of 2^kPwmBits - 1 = 2047 (linear duty, ~0.2 %)
constexpr uint16_t kHighCounts = 100;    // ~5 %

// Bit i set = layout channel i breathes. Setup-needed mode: none (no output is known).
inline uint8_t channels(const FixtureProfile& f) {
  const ChannelLayout& l = *f.layout;
  const bool white = layout::hasPrimaryWhite(l);
  uint8_t mask = 0;
  for (uint8_t i = 0; i < l.count; ++i) {
    const Channel c = l.roles[i];
    const bool isWhite = c == Channel::W || c == Channel::CW || c == Channel::WW;
    if (white ? isWhite : true) mask = static_cast<uint8_t>(mask | (1u << i));
  }
  return mask;
}

}  // namespace otaglow
