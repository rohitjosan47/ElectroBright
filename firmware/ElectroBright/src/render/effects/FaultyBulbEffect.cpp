// Mode 7 — Faulty bulb.
//
// Steady light with a faint mains ripple, interrupted by faults. Every fault
// is pre-generated as a list of (level, base duration) steps; the durations
// are scaled by the live speed factor while playing, so the glitch speed
// slider acts instantly and one small sequencer covers all fault kinds:
//   45 % flicker-out  (1–4 quick drops)
//   20 % dropout      (dark, then a struggling, back-sliding restart)
//   25 % sputter      (jittering in a dim band)
//   10 % arc          (bright double spike)

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

void FaultyBulbEffect::reset(Rng& rng) {
  seed_ = rng.next();
  faulting_ = false;
  steadyT_ = 0.0f;
  steadyFactor_ = 0.3f;  // first glitch soon after selecting the mode
  count_ = 0;
  idx_ = 0;
  ripple_.reset();
}

void FaultyBulbEffect::push(float level, float ms) {
  if (count_ >= kMaxSteps) return;
  steps_[count_].level = mathx::clamp01(level);
  steps_[count_].ms = static_cast<uint16_t>(mathx::clampf(ms, 1.0f, 60000.0f));
  ++count_;
}

void FaultyBulbEffect::buildFault(Rng& rng) {
  count_ = 0;
  const uint32_t roll = rng.below(100);
  if (roll < 45) {  // flicker-out
    const uint32_t blips = 1 + rng.below(4);
    for (uint32_t i = 0; i < blips; ++i) {
      push(rng.range(0.05f, 0.2f), rng.range(40, 80));
      push(rng.range(0.6f, 1.0f), rng.range(30, 60));
    }
  } else if (roll < 65) {  // dropout + struggling restart
    push(0.0f, rng.range(400, 600));
    float level = 0.0f;
    while (count_ < kMaxSteps - 1 && level < 1.0f) {
      if (level > 0.1f && rng.chance(0.2f)) {
        level -= rng.range(0.03f, 0.08f);
      } else {
        level += rng.range(0.04f, 0.12f);
      }
      push(level, rng.range(40, 90));
    }
  } else if (roll < 90) {  // sputter
    const uint32_t n = 8 + rng.below(8);
    for (uint32_t i = 0; i < n; ++i) push(rng.range(0.25f, 0.6f), rng.range(20, 60));
  } else {  // arc double flash
    push(1.0f, rng.range(5, 15));
    push(0.75f, rng.range(3, 8));
    push(1.0f, rng.range(5, 15));
  }
  idx_ = 0;
  stepT_ = 0.0f;
}

LinColor FaultyBulbEffect::render(const EffectInput& in) {
  Rng& rng = *in.rng;
  const float k = geo(in.speed, 1.5f, 0.5f);

  if (!faulting_) {
    steadyT_ += in.dtMs;
    if (steadyT_ >= geo(in.freq, 12000.0f, 1500.0f) * steadyFactor_) {
      buildFault(rng);
      faulting_ = count_ > 0;
    }
  }

  float level;
  if (faulting_) {
    stepT_ += in.dtMs;
    while (idx_ < count_ && stepT_ >= steps_[idx_].ms * k) {
      stepT_ -= steps_[idx_].ms * k;
      ++idx_;
    }
    if (idx_ >= count_) {
      faulting_ = false;
      steadyT_ = 0.0f;
      steadyFactor_ = rng.range(0.4f, 1.6f);
      level = 0.94f;
    } else {
      level = steps_[idx_].level;
    }
  } else {
    // Steady: ~8 Hz mains-like ripple of +/- 3 % around 94 %.
    ripple_.advance(in.dtMs * 0.008f);
    level = 0.94f - 0.06f * (noise::value(ripple_.cell(), ripple_.frac(), seed_) - 0.5f);
  }
  return in.base * color::linearFromLevel(level);
}
