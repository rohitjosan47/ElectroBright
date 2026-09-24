// Modes 11 (Fire) and 13 (Candle): brightness modulated by fractal value
// noise. The speed slider scales the noise *time axis* directly, so faster
// really is faster; the frequency slider sets how deep the flicker goes.

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

// ------------------------------------------------------------------ Fire (11)
void FireEffect::reset(Rng& rng) {
  seed_ = rng.next();
  t_.reset();
  flareT_ = flareMs_ = flareGain_ = 0.0f;
}

LinColor FireEffect::render(const EffectInput& in) {
  Rng& rng = *in.rng;
  const float ts = geo(in.speed, 0.4f, 2.5f);
  const float e = mathx::level01(in.freq);

  t_.advance(in.dtMs * 0.0017f * ts);  // ~1.7 Hz base flicker at speed 1x
  const float n = noise::fbm(t_, seed_, 3);
  const float depth = mathx::lerp(0.15f, 0.60f, e);

  // Occasional flare-ups (more frequent with intensity and speed).
  if (flareT_ < flareMs_) {
    flareT_ += in.dtMs;
  } else {
    const float perSecond = mathx::lerp(0.05f, 0.4f, e) * ts;
    if (rng.chance(perSecond * in.dtMs / 1000.0f)) {
      flareT_ = 0.0f;
      flareMs_ = rng.range(150.0f, 400.0f) / ts;
      flareGain_ = rng.range(0.6f, 1.0f);
    }
  }
  const float flare = flareT_ < flareMs_ ? flareGain_ * mathx::bump(flareT_ / flareMs_) : 0.0f;

  const float level = 0.85f * (1.0f - depth * n) + 0.15f * flare;
  return in.base * color::linearFromLevel(level);
}

// ---------------------------------------------------------------- Candle (13)
void CandleEffect::reset(Rng& rng) {
  seed_ = rng.next();
  t_.reset();
  draughtIn_ = rng.range(6000.0f, 15000.0f);
  draughtT_ = draughtMs_ = 0.0f;
}

LinColor CandleEffect::render(const EffectInput& in) {
  Rng& rng = *in.rng;
  const float ts = geo(in.speed, 0.4f, 2.5f);
  const float e = mathx::level01(in.freq);

  t_.advance(in.dtMs * 0.002f * ts);  // ~2 Hz base flicker at speed 1x
  const float depth = mathx::lerp(0.04f, 0.35f, e);
  float level = 1.0f - depth * noise::fbm(t_, seed_, 3);

  // Rare draught: a smooth dip (14–55 % depending on depth) lasting 150–400 ms.
  if (draughtT_ < draughtMs_) {
    draughtT_ += in.dtMs;
    level *= 1.0f - draughtDepth_ * mathx::bump(draughtT_ / draughtMs_);
  } else {
    draughtIn_ -= in.dtMs;
    if (draughtIn_ <= 0.0f) {
      draughtT_ = 0.0f;
      draughtMs_ = rng.range(150.0f, 400.0f);
      // Scaled by the depth slider so "Flicker Depth 1" is genuinely calm.
      draughtDepth_ = rng.range(0.35f, 0.55f) * mathx::lerp(0.4f, 1.0f, e);
      draughtIn_ = rng.range(6000.0f, 15000.0f);
    }
  }
  return in.base * color::linearFromLevel(level);
}
