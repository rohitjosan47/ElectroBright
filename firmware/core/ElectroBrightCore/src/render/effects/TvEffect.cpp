// Mode 5 — TV simulator.
//
// A sequence of "scenes" (daylight blue, warm interior, dark scene, bright
// white). Each scene either hard-cuts in or fades in; the picture flickers
// with smooth noise at ~12 Hz like changing on-screen content.

#include <math.h>

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

void TvEffect::reset(Rng& rng) {
  seed_ = rng.next();
  flicker_.reset();
  newScene(rng, true, 1.0f);
}

void TvEffect::newScene(Rng& rng, bool forceCut, float cutShare) {
  switch (rng.below(4)) {
    case 0:  // daylight / outdoor: bluish
      th_ = rng.range(190, 240); ts_ = rng.range(0.3f, 0.8f); tv_ = rng.range(0.5f, 1.0f);
      break;
    case 1:  // warm interior
      th_ = rng.range(10, 40); ts_ = rng.range(0.4f, 0.7f); tv_ = rng.range(0.4f, 0.85f);
      break;
    case 2:  // dark scene
      th_ = rng.range(200, 260); ts_ = rng.range(0.2f, 0.6f); tv_ = rng.range(0.08f, 0.3f);
      break;
    default:  // bright white (titles, snow, studio)
      th_ = rng.range(0, 360); ts_ = rng.range(0.0f, 0.2f); tv_ = rng.range(0.8f, 1.0f);
      break;
  }
  sceneT_ = 0.0f;
  sceneFactor_ = rng.range(0.5f, 1.5f);
  if (forceCut || rng.chance(cutShare)) {
    h_ = th_;
    s_ = ts_;
    v_ = tv_;
  }
}

LinColor TvEffect::render(const EffectInput& in) {
  Rng& rng = *in.rng;
  const float f01 = mathx::level01(in.freq);

  sceneT_ += in.dtMs;
  if (sceneT_ >= geo(in.speed, 8000.0f, 1000.0f) * sceneFactor_) {
    newScene(rng, false, mathx::lerp(0.10f, 0.80f, f01));
  }

  // Fade towards the target scene (hue along the shortest arc).
  const float a = mathx::smoothingAlpha(in.dtMs, geo(in.speed, 1200.0f, 200.0f));
  float dh = fmodf(th_ - h_ + 540.0f, 360.0f) - 180.0f;
  h_ = fmodf(h_ + dh * a + 360.0f, 360.0f);
  s_ += (ts_ - s_) * a;
  v_ += (tv_ - v_) * a;

  flicker_.advance(in.dtMs * 0.012f);  // ~12 Hz
  const float depth = mathx::lerp(0.03f, 0.25f, f01);
  const float v = v_ * (1.0f - depth * noise::fbm(flicker_, seed_, 2));
  return color::hsvToLinear(h_, s_, v);
}
