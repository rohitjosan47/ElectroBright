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
// temperature instead: see colourToWhites().

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
//   warmth = 0.5 + 0.5 (r - b) / max(r, b): red/orange/yellow -> 1 (warm LED),
//            blue/cyan -> 0 (cool LED), white/green/magenta -> 0.5 (both);
//   cool += level * min(1, 2 (1 - warmth)), warm += level * min(1, 2 warmth),
// so a neutral colour lights both LEDs at its level. Existing white light (w,
// ww) is kept; if a white then exceeds full scale both are scaled down
// together, which keeps the warm/cool balance.
inline LinColor colourToWhites(const LinColor& c) {
  float level = c.r > c.g ? c.r : c.g;
  if (c.b > level) level = c.b;
  float cool = c.w;
  float warm = c.ww;
  if (level > 0.0f) {
    const float rb = c.r > c.b ? c.r : c.b;
    const float warmth = rb > 0.0f ? 0.5f + 0.5f * (c.r - c.b) / rb : 0.5f;
    const float toCool = 2.0f * (1.0f - warmth);
    const float toWarm = 2.0f * warmth;
    cool += level * (toCool < 1.0f ? toCool : 1.0f);
    warm += level * (toWarm < 1.0f ? toWarm : 1.0f);
  }
  const float peak = cool > warm ? cool : warm;
  if (peak > 1.0f) {
    cool /= peak;
    warm /= peak;
  }
  return {0.0f, 0.0f, 0.0f, cool, warm};
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
