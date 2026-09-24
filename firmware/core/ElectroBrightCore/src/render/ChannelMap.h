#pragma once
// Last render stage: the effect pipeline's linear RGBW colour -> the fixture's
// physical channels.
//
// Effects are shared by every fixture and may emit white-channel light (the
// club white strobe, the fireworks flash, a user colour with W). A layout
// without a W channel renders that light with its RGB LEDs instead: W is
// replaced by `whiteMix` (linear RGB), and if a channel then exceeds full
// scale all channels are scaled down together, which keeps the hue.

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

inline float component(const LinColor& c, Channel ch) {
  switch (ch) {
    case Channel::R: return c.r;
    case Channel::G: return c.g;
    case Channel::B: return c.b;
    case Channel::W: break;
  }
  return c.w;
}

}  // namespace chanmap
