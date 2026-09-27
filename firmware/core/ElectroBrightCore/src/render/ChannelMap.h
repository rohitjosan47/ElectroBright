#pragma once
// Last render stage: the effect pipeline's linear RGBW colour -> the fixture's
// physical channels.
//
// Effects are shared by every fixture and may emit white-channel light (the
// club white strobe, the fireworks flash, a user colour with W). Each LED takes
// its slot: R/G/B, W or CW <- w, WW <- ww. A layout without any white LED
// renders the `w` light with its RGB LEDs instead: W is replaced by `whiteMix`
// (linear RGB), and if a channel then exceeds full scale all channels are
// scaled down together, which keeps the hue. (`ww` is only ever non-zero on
// layouts with a WW LED, apart from effect white, which always also sets `w`.)
//
// A layout without colour LEDs (CCT: cool + warm white) renders the coloured
// light of effects (rainbow, TV, police, palettes, embers) as white
// temperature instead: see colourToWhites(). A single white LED (W) shows it
// as brightness: see colourToWhite().

#include <math.h>

#include "../core/Types.h"
#include "../fixture/ChannelLayout.h"

namespace chanmap {

inline LinColor foldWhite(const LinColor& c, const LinColor& mix) {
  LinColor m{c.r + c.w * mix.r, c.g + c.w * mix.g, c.b + c.w * mix.b, 0.0f};
  float peak = m.r > m.g ? m.r : m.g;
  if (m.b > peak) peak = m.b;
  if (peak > 1.0f) m = m * (1.0f / peak);
  return m;
}

// Coloured light -> cool/warm white for fixtures with only white LEDs.
//   level  = max(r, g, b): a colour is as bright as its strongest channel, so
//            saturated effect colours stay fully visible;
//   warmth = 0.5 + 0.5 sat cos(hue - 15 deg), sat = (max - min) / max: a smooth
//            wave around the hue circle, warmest at red/orange, coolest at
//            cyan/blue (195 deg), neutral for white; no jumps or plateaus, so
//            a hue sweep (Rainbow) becomes a smooth temperature sweep;
//   cool += level (1 - warmth), warm += level warmth,
// so cool + warm always equals the colour's level (steady brightness). Existing
// white light (w, ww) is kept; if a white then exceeds full scale both are
// scaled down together, which keeps the warm/cool balance.
inline float colourWarmth(const LinColor& c) {
  float hi = c.r > c.g ? c.r : c.g;
  if (c.b > hi) hi = c.b;
  float lo = c.r < c.g ? c.r : c.g;
  if (c.b < lo) lo = c.b;
  const float chroma = hi - lo;
  if (!(hi > 0.0f) || !(chroma > 0.0f)) return 0.5f;
  // HSV hue in sixths of the circle, 0..6.
  float h;
  if (hi == c.r) {
    h = (c.g - c.b) / chroma;
    if (h < 0.0f) h += 6.0f;
  } else if (hi == c.g) {
    h = 2.0f + (c.b - c.r) / chroma;
  } else {
    h = 4.0f + (c.r - c.g) / chroma;
  }
  constexpr float kSixth = 1.04719755f;     // 60 deg in radians
  constexpr float kWarmest = 0.26179939f;   // 15 deg: between red and orange
  return 0.5f + 0.5f * (chroma / hi) * cosf(h * kSixth - kWarmest);
}

inline LinColor colourToWhites(const LinColor& c) {
  float level = c.r > c.g ? c.r : c.g;
  if (c.b > level) level = c.b;
  float cool = c.w;
  float warm = c.ww;
  if (level > 0.0f) {
    const float warmth = colourWarmth(c);
    cool += level * (1.0f - warmth);
    warm += level * warmth;
  }
  const float peak = cool > warm ? cool : warm;
  if (peak > 1.0f) {
    cool /= peak;
    warm /= peak;
  }
  return {0.0f, 0.0f, 0.0f, cool, warm};
}

// Coloured light -> a single white LED: the colour's strongest channel adds
// to the white light (same level rule as colourToWhites), capped at full scale.
inline LinColor colourToWhite(const LinColor& c) {
  float level = c.r > c.g ? c.r : c.g;
  if (c.b > level) level = c.b;
  const float w = c.w + level;
  return {0.0f, 0.0f, 0.0f, w > 1.0f ? 1.0f : w, 0.0f};
}

inline float component(const LinColor& c, Channel ch) {
  switch (ch) {
    case Channel::R: return c.r;
    case Channel::G: return c.g;
    case Channel::B: return c.b;
    case Channel::WW: return c.ww;
    case Channel::W:
    case Channel::CW: break;
  }
  return c.w;
}

}  // namespace chanmap
