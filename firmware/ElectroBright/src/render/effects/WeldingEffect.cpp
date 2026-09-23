// Mode 8 — Welding.
//
// One weld cycle, modelled on a real (MIG / stick) arc:
//
//   Gap ── cooling bead glow + hot-spatter twinkles, then the next weld
//   Ignition ── 1–3 scratch-start contact sparks before the arc "catches"
//   Arc ── baseline 80 % with
//            wander   slow drift of arc length / hand position (~2.5 Hz)
//            weave    welder weaving on long beads (2 Hz)
//            shimmer  plasma flicker (~55 Hz, resolved by the 200 Hz frames)
//            crackle  short-circuit metal-transfer dips (~10 /s, 5–15 ms)
//            pops     spatter flashes above the arc (~2 /s, 10–30 ms)
//   Outage ── occasionally the arc drops out (electrode sticks) and re-strikes
//   Crater fill ── half the welds end with 1–2 short re-arcs
//
// Sliders: Weld Length (speed) sets the arc time, 0.3 s tacks -> 8 s beads.
// Weld Gap (frequency) sets the pause between welds, 0.8 s -> 12 s. Short
// lengths sometimes turn into a run of 2–4 tacks. Durations are recomputed
// from the live sliders every frame (only the random factors are stored), so
// moving a slider takes effect immediately.
//
// All levels are perceptual (0..1) and converted to linear light at the end;
// the colour is the user's base colour.

#include <math.h>

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

namespace {
constexpr float kArcBase = 0.80f;          // leaves headroom for spatter pops
constexpr float kGlowStart = 0.14f;        // cooling bead right after the arc stops
constexpr float kGlowOff = 0.01f;          // below this the glow snaps to true black
constexpr float kTackThresholdMs = 700.0f; // welds shorter than this may become tack runs

float lengthMs(uint8_t speed, float factor) { return geo(speed, 300.0f, 8000.0f) * factor; }
float gapMs(uint8_t freq, float factor) { return geo(freq, 800.0f, 12000.0f) * factor; }
}  // namespace

void WeldingEffect::reset(Rng& rng) {
  seed_ = rng.next();
  pulses_.clear();
  wander_.reset();
  shimmer_.reset();
  glow_ = 0.0f;
  tacksLeft_ = 0;
  tackGap_ = false;
  dipT_ = dipMs_ = 0.0f;
  weaveT_ = 0.0f;
  phase_ = Phase::Gap;
  t_ = 0.0f;
  gapFactor_ = 0.0f;  // zero gap: the first weld strikes immediately
}

float WeldingEffect::scheduleSparks(Rng& rng, float startMs, int count) {
  float at = startMs;
  float last = startMs;
  for (int i = 0; i < count; ++i) {
    // Contact spark: instant rise, brief hold, very fast decay.
    pulses_.addIn(at, 0.0f, rng.range(5.0f, 20.0f), rng.range(8.0f, 15.0f), rng.range(0.7f, 1.0f));
    last = at;
    at += rng.range(30.0f, 110.0f);
  }
  return last;
}

void WeldingEffect::startWeld(const EffectInput& in) {
  Rng& rng = *in.rng;
  lenFactor_ = rng.range(0.7f, 1.3f);
  const float len = lengthMs(in.speed, lenFactor_);
  if (!tackGap_ && len < kTackThresholdMs && rng.chance(0.5f)) {
    tacksLeft_ = static_cast<uint8_t>(1 + rng.below(3));  // this tack + 1..3 more
  }
  outagePlanned_ = len > 1500.0f && rng.chance(0.12f);
  outageFrac_ = rng.range(0.2f, 0.8f);
  craterPlanned_ = rng.chance(0.5f);
  arcMs_ = 0.0f;
  weaveT_ = 0.0f;
  dipT_ = dipMs_ = 0.0f;

  phase_ = Phase::Ignition;
  t_ = 0.0f;
  const float lastSpark = scheduleSparks(rng, 0.0f, static_cast<int>(1 + rng.below(3)));
  catchMs_ = lastSpark + rng.range(20.0f, 60.0f);
}

void WeldingEffect::finishWeld(Rng& rng) {
  glow_ = glow_ > kGlowStart ? glow_ : kGlowStart;
  glowTauMs_ = fminf(400.0f + 0.15f * arcMs_, 1500.0f);  // bigger bead, longer glow
  phase_ = Phase::Gap;
  t_ = 0.0f;
  if (tacksLeft_ > 0) {
    --tacksLeft_;
    tackGap_ = true;
    tackGapMs_ = rng.range(150.0f, 400.0f);
  } else {
    tackGap_ = false;
    gapFactor_ = rng.range(0.6f, 1.4f);
  }
}

float WeldingEffect::arcLevel(const EffectInput& in, float lenTargetMs) {
  Rng& rng = *in.rng;
  const float dt = in.dtMs;
  float level = kArcBase;

  wander_.advance(dt * 0.0025f);  // ~2.5 Hz
  level += (noise::fbm(wander_, seed_, 2) - 0.5f) * 0.10f;

  if (lenTargetMs > 2000.0f) {  // welders weave on long beads
    weaveT_ += dt;
    level += 0.03f * sinf(2.0f * mathx::kPi * 2.0f * weaveT_ / 1000.0f);
  }

  shimmer_.advance(dt * 0.055f);  // ~55 Hz plasma flicker
  level += (noise::value(shimmer_.cell(), shimmer_.frac(), seed_ ^ 0xA5A5A5A5u) - 0.5f) * 0.14f;

  // Short-circuit transfer: the wire touches the pool and the arc dips.
  if (dipT_ < dipMs_) {
    dipT_ += dt;
    level -= dipDepth_;
  } else if (rng.chance(10.0f * dt / 1000.0f)) {
    dipT_ = 0.0f;
    dipMs_ = rng.range(5.0f, 15.0f);
    dipDepth_ = rng.range(0.15f, 0.35f);
  }

  // Spatter pop: a brief flash above the arc.
  if (rng.chance(2.0f * dt / 1000.0f)) {
    pulses_.addIn(0.0f, 0.0f, rng.range(5.0f, 15.0f), rng.range(5.0f, 10.0f), rng.range(0.15f, 0.20f));
  }
  return level;
}

LinColor WeldingEffect::render(const EffectInput& in) {
  Rng& rng = *in.rng;
  const float dt = in.dtMs;
  const float len = lengthMs(in.speed, lenFactor_);

  if (glow_ > 0.0f) {
    glow_ *= expf(-dt / glowTauMs_);
    if (glow_ < kGlowOff) glow_ = 0.0f;
  }

  float level = 0.0f;
  switch (phase_) {
    case Phase::Gap: {
      t_ += dt;
      // Hot spatter on the cooling bead twinkles now and then.
      if (glow_ > 0.0f && rng.chance(6.0f * (glow_ / kGlowStart) * dt / 1000.0f)) {
        pulses_.addIn(0.0f, 0.0f, rng.range(5.0f, 15.0f), rng.range(4.0f, 8.0f), rng.range(0.10f, 0.20f));
      }
      level = glow_;
      const float gap = tackGap_ ? tackGapMs_ : gapMs(in.freq, gapFactor_);
      if (t_ >= gap) startWeld(in);
      break;
    }
    case Phase::Ignition:
      t_ += dt;
      level = glow_;
      if (t_ >= catchMs_) {
        phase_ = Phase::Arc;
        rampMs_ = 0.0f;
      }
      break;

    case Phase::Arc: {
      arcMs_ += dt;
      rampMs_ += dt;
      level = arcLevel(in, len);
      if (rampMs_ < 30.0f) level *= 0.5f + 0.5f * (rampMs_ / 30.0f);  // arc catching

      if (outagePlanned_ && arcMs_ >= outageFrac_ * len && arcMs_ < len) {
        // Electrode sticks / arc blows out, then the welder re-strikes.
        outagePlanned_ = false;
        phase_ = Phase::Outage;
        t_ = 0.0f;
        const float off = rng.range(40.0f, 150.0f);
        const float lastSpark = scheduleSparks(rng, off, static_cast<int>(1 + rng.below(2)));
        catchMs_ = lastSpark + rng.range(20.0f, 60.0f);
      } else if (arcMs_ >= len) {
        if (craterPlanned_) {
          // Crater fill: the arc stops, then 1–2 short re-arcs close the crater.
          craterPlanned_ = false;
          phase_ = Phase::CraterFill;
          t_ = 0.0f;
          float at = rng.range(40.0f, 90.0f);
          const int n = static_cast<int>(1 + rng.below(2));
          for (int i = 0; i < n; ++i) {
            const float hold = rng.range(40.0f, 80.0f);
            pulses_.addIn(at, 0.0f, hold, 6.0f, rng.range(0.7f, 0.85f));
            at += hold + rng.range(40.0f, 90.0f);
          }
          endMs_ = at;
        } else {
          finishWeld(rng);
        }
      }
      break;
    }

    case Phase::Outage:
      t_ += dt;
      if (t_ >= catchMs_) {
        phase_ = Phase::Arc;
        rampMs_ = 0.0f;
      }
      break;

    case Phase::CraterFill:
      t_ += dt;
      if (t_ >= endMs_) finishWeld(rng);
      break;
  }

  level += pulses_.advance(dt);
  if (level <= 0.0f) return kBlack;
  return in.base * color::linearFromLevel(mathx::clamp01(level));
}
