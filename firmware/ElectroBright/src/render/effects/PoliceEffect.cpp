// Mode 12 — Police strobe.
//
// Side A bursts N flashes, pause, side B bursts N flashes, pause, repeat.
// The current segment's length is evaluated live, so both sliders act on the
// very next segment boundary without restarting the pattern.

#include "../../core/MathUtil.h"
#include "Effects.h"

using mathx::geo;

void PoliceEffect::reset(Rng&) {
  side_ = 0;
  flash_ = 0;
  on_ = true;
  pausing_ = false;
  t_ = 0.0f;
}

LinColor PoliceEffect::render(const EffectInput& in) {
  const float onMs = geo(in.speed, 150.0f, 40.0f);
  const float pauseMs = geo(in.speed, 400.0f, 100.0f);
  const uint8_t flashes = static_cast<uint8_t>(1.0f + 5.0f * mathx::level01(in.freq) + 0.5f);  // 1..6

  t_ += in.dtMs;
  for (int guard = 0; guard < 16; ++guard) {
    const float segMs = pausing_ ? pauseMs : onMs;
    if (t_ < segMs) break;
    t_ -= segMs;
    if (pausing_) {
      pausing_ = false;
      side_ ^= 1;
      flash_ = 0;
      on_ = true;
    } else if (on_) {
      on_ = false;
    } else {
      ++flash_;
      if (flash_ >= flashes) {
        pausing_ = true;
      } else {
        on_ = true;
      }
    }
  }

  if (pausing_ || !on_) return kBlack;
  if (in.colorMode == 1) {
    return side_ == 0 ? LinColor{1.0f, 0.0f, 0.0f, 0.0f} : LinColor{0.0f, 0.0f, 1.0f, 0.0f};
  }
  return side_ == 0 ? in.policeA : in.policeB;
}
