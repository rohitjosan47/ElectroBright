// Mode 4 — Fireworks.
//
// One shell = Idle (dim ember) -> Rise (warm launch glow) -> Flash (white
// burst) -> Burst (full shell colour) -> Crackle (decaying random sparkles)
// -> Afterglow (fade out). Every duration is a *base* value multiplied by the
// live speed factor each frame, and the idle wait is a stored random factor
// times the live frequency interval, so both sliders act immediately.

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

namespace {
constexpr float kRiseMs = 400.0f;
constexpr float kFlashMs = 30.0f;
constexpr float kBurstMs = 80.0f;
constexpr float kAfterglowMs = 500.0f;
constexpr float kCrackleEnd = 0.07f;   // perceptual level where crackle hands over to afterglow
constexpr float kCeilingDecay = 0.86f;
}  // namespace

void FireworksEffect::reset(Rng&) {
  stage_ = Stage::Idle;
  t_ = 0.0f;
  idleFactor_ = 0.15f;  // first launch comes quickly after selecting the mode
}

LinColor FireworksEffect::pickColor(const EffectInput& in) {
  manual_ = in.colorMode == 0;
  if (manual_) return in.base;
  Rng& rng = *in.rng;
  uint8_t bucket = static_cast<uint8_t>(rng.below(5));
  if (bucket == lastBucket_) bucket = static_cast<uint8_t>(rng.below(5));
  lastBucket_ = bucket;
  switch (bucket) {
    case 0: return color::hsvToLinear(rng.range(40, 51), 1.0f, 1.0f);    // gold
    case 1: return color::hsvToLinear(rng.range(0, 11), 1.0f, 1.0f);     // red
    case 2: return color::hsvToLinear(rng.range(200, 221), 0.6f, 1.0f);  // ice blue
    case 3: return color::hsvToLinear(rng.range(110, 141), 1.0f, 1.0f);  // green
    default: return color::hsvToLinear(rng.range(280, 321), 1.0f, 1.0f); // purple / magenta
  }
}

LinColor FireworksEffect::render(const EffectInput& in) {
  const float k = geo(in.speed, 1.6f, 0.5f);
  Rng& rng = *in.rng;
  t_ += in.dtMs;
  // In manual mode the shell follows live base-colour edits.
  const LinColor shell = manual_ ? in.base : shell_;

  switch (stage_) {
    case Stage::Idle: {
      const float wait = geo(in.freq, 8000.0f, 800.0f) * idleFactor_;
      if (t_ >= wait) {
        shell_ = pickColor(in);
        stage_ = Stage::Rise;
        t_ = 0.0f;
      }
      return LinColor{1.0f, 0.3f, 0.0f, 0.0f} * color::linearFromLevel(0.03f);  // faint ember
    }
    case Stage::Rise: {
      const float dur = kRiseMs * k;
      if (t_ >= dur) {
        stage_ = Stage::Flash;
        t_ = 0.0f;
      }
      const float lvl = 0.25f * mathx::clamp01(t_ / dur);
      return LinColor{1.0f, 0.55f, 0.16f, 0.0f} * color::linearFromLevel(lvl);
    }
    case Stage::Flash: {
      if (t_ >= mathx::clampf(kFlashMs * k, 20.0f, 60.0f)) {
        stage_ = Stage::Burst;
        t_ = 0.0f;
      }
      return LinColor{1.0f, 0.9f, 0.8f, 0.6f};
    }
    case Stage::Burst: {
      if (t_ >= kBurstMs * k) {
        stage_ = Stage::Crackle;
        t_ = 0.0f;
        ceiling_ = 1.0f;
        spark_ = 1.0f;
        sparkLenMs_ = rng.range(15.0f, 80.0f);
      }
      return shell;
    }
    case Stage::Crackle: {
      if (t_ >= sparkLenMs_ * k) {
        t_ = 0.0f;
        ceiling_ *= kCeilingDecay;
        if (ceiling_ < kCrackleEnd) {
          stage_ = Stage::Afterglow;
          return shell * color::linearFromLevel(kCrackleEnd);
        }
        spark_ = rng.range(ceiling_ * 0.2f, ceiling_);
        sparkLenMs_ = rng.range(15.0f, 80.0f);
      }
      return shell * color::linearFromLevel(spark_);
    }
    case Stage::Afterglow:
    default: {
      const float dur = kAfterglowMs * k;
      if (t_ >= dur) {
        stage_ = Stage::Idle;
        t_ = 0.0f;
        idleFactor_ = rng.range(0.5f, 1.5f);
        return kBlack;
      }
      return shell * color::linearFromLevel(kCrackleEnd * (1.0f - t_ / dur));
    }
  }
}
