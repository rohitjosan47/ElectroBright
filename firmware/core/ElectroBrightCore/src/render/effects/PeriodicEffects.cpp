// Modes 2 (Blink), 3 (Breath) and 10 (Rainbow): purely
// periodic effects driven by a phase accumulator. The period is re-evaluated
// every frame, so the rate slider acts instantly and without a jump.

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

// ---------------------------------------------------------------- Blink (2)
void BlinkEffect::reset(Rng&) { phase_ = 0.0f; }

LinColor BlinkEffect::render(const EffectInput& in) {
  const float period = geo(in.freq, 1600.0f, 120.0f);
  phase_ = mathx::wrap01(phase_ + in.dtMs / period);

  // 4 ms linear edges: softer on the MOSFETs / EMI, invisible to the eye.
  const float ramp = mathx::clampf(4.0f / period, 0.0001f, 0.1f);
  float env;
  if (phase_ < ramp) {
    env = phase_ / ramp;
  } else if (phase_ < 0.5f) {
    env = 1.0f;
  } else if (phase_ < 0.5f + ramp) {
    env = 1.0f - (phase_ - 0.5f) / ramp;
  } else {
    env = 0.0f;
  }
  return in.base * env;
}

// ---------------------------------------------------------------- Breath (3)
namespace {
struct BreathShape {
  float rise, hold, fall;
};
BreathShape breathShape(uint8_t speed) {
  const float u = mathx::level01(speed);
  const float rise = 0.5f - 0.3f * u;
  const float hold = 0.25f * u;
  return {rise, hold, 1.0f - rise - hold};
}
}  // namespace

void BreathEffect::reset(Rng&) {
  // Start at the top of the breath so the new mode is visible immediately.
  phase_ = breathShape(5).rise;
}

LinColor BreathEffect::render(const EffectInput& in) {
  const float period = geo(in.freq, 8000.0f, 1000.0f);
  phase_ = mathx::wrap01(phase_ + in.dtMs / period);

  const BreathShape sh = breathShape(in.speed);
  float e;
  if (phase_ < sh.rise) {
    e = mathx::easeInOut(phase_ / sh.rise);
  } else if (phase_ < sh.rise + sh.hold) {
    e = 1.0f;
  } else {
    e = 1.0f - mathx::easeInOut((phase_ - sh.rise - sh.hold) / sh.fall);
  }
  constexpr float kFloor = 0.03f;  // perceptual floor: never fully dark
  return in.base * color::linearFromLevel(kFloor + (1.0f - kFloor) * e);
}

// ---------------------------------------------------------------- Rainbow (10)
void RainbowEffect::reset(Rng&) {}  // keep the hue across mode switches

LinColor RainbowEffect::render(const EffectInput& in) {
  const float period = geo(in.freq, 30000.0f, 3000.0f);
  hue_ += 360.0f * in.dtMs / period;
  if (hue_ >= 360.0f) hue_ -= 360.0f * static_cast<float>(static_cast<int>(hue_ / 360.0f));
  return color::hsvToLinear(hue_, 1.0f, 1.0f);
}
