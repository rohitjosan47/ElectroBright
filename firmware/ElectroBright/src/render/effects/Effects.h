#pragma once
// All lighting modes. Slider semantics (S = speed, F = frequency) are listed
// per class; see ModeRegistry.h for the UI names.

#include <stdint.h>

#include "../../core/Noise.h"
#include "../../core/ShuffleBag.h"
#include "../Effect.h"
#include "Pulses.h"

// 1 — Solid: the smoothed base colour.
class SolidEffect final : public Effect {
 public:
  void reset(Rng&) override {}
  LinColor render(const EffectInput& in) override { return in.base; }
};

// 2 — Blink. F: period 1600 -> 120 ms. 50 % duty with 4 ms edge ramps.
class BlinkEffect final : public Effect {
 public:
  void reset(Rng&) override;
  LinColor render(const EffectInput& in) override;

 private:
  float phase_ = 0.0f;
};

// 3 — Breath. F: breathing period 8 s -> 1 s. S: curve shape from a soft
// symmetric sine (1) to a quick inhale, a hold and a long exhale (10).
class BreathEffect final : public Effect {
 public:
  void reset(Rng&) override;
  LinColor render(const EffectInput& in) override;

 private:
  float phase_ = 0.0f;
};

// 4 — Fireworks. S: burst dynamics (x1.6 -> x0.5 durations). F: launch
// interval 8 s -> 0.8 s (+/- 50 %). colorMode 1 = random palette, 0 = base.
class FireworksEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  enum class Stage : uint8_t { Idle, Rise, Flash, Burst, Crackle, Afterglow };
  LinColor pickColor(const EffectInput& in);

  Stage stage_ = Stage::Idle;
  float t_ = 0.0f;
  float idleFactor_ = 0.2f;
  LinColor shell_ = {1, 1, 1, 0};
  bool manual_ = false;
  float ceiling_ = 1.0f;
  float spark_ = 1.0f;
  float sparkLenMs_ = 40.0f;
  uint8_t lastBucket_ = 0xFF;
};

// 5 — TV simulator. S: scene length 8 s -> 1 s and fade speed.
// F: share of hard cuts (10 -> 80 %) and flicker depth.
class TvEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  void newScene(Rng& rng, bool forceCut, float cutShare);

  float h_ = 210, s_ = 0.4f, v_ = 0.6f;
  float th_ = 210, ts_ = 0.4f, tv_ = 0.6f;
  float sceneT_ = 0.0f;
  float sceneFactor_ = 1.0f;
  NoiseTime flicker_;
  uint32_t seed_ = 0;
};

// 6 — Thunderstorm. S: stroke tempo (typical gap between strokes 160 -> 40 ms,
// irregular like real lightning). F: strike rate (about 4 -> 30 strikes per
// minute, +/-20 % natural spacing). Every strike is one of five real-world
// strike characters, drawn from a shuffle bag for controlled variety; every
// strike contains a full-power bolt. Completely dark between strikes; uses the
// base colour. See ThunderEffect.cpp for the physical model.
class ThunderEffect final : public Effect {
 public:
  enum class Character : uint8_t { Crack, Classic, Stutter, Burner, BuildUp, kCount };

  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

  // Introspection (tests / tools).
  Character lastCharacter() const { return character_; }
  uint32_t strikeCount() const { return strikes_; }

 private:
  struct Stroke {
    float at;    // strike time of the stroke onset (ms)
    float peak;  // linear peak
    float hold;  // time at peak (ms)
    float end;   // when its bright part is over (ms)
  };

  void composeStrike(Rng& rng, uint8_t speed);
  Stroke addStroke(Rng& rng, float at, float perceptual, bool main);
  Stroke addStrokeMaybeDoublet(Rng& rng, float at, float perceptual, bool main, float doubletChance);
  Stroke aftershocks(Rng& rng, Stroke prev, int count, float medianGapMs, float sigma, float doubletChance);
  float startContinuingCurrent(Rng& rng, const Stroke& after, float glowBaseLinear, float durationMs,
                               int mComponents);
  float continuingCurrent(float t, float dt);

  PulsePool pool_;
  ShuffleBag<static_cast<uint8_t>(Character::kCount)> bag_;
  Character character_ = Character::Classic;
  uint32_t strikes_ = 0;
  bool flashing_ = false;
  float firstInMs_ = 0.0f;      // countdown to the first strike after selecting the mode
  float sinceStartMs_ = 0.0f;   // time since the last strike started
  float jitter_ = 1.0f;         // per-interval spacing factor (0.8–1.2)
  float quietMs_ = 0.0f;        // guaranteed darkness after a strike
  float strikeT_ = 0.0f;        // time since the current strike started
  float strikeEndMs_ = 0.0f;    // the strike (including its final fade) is over at this time
  // Continuing current (sustained channel glow) of the current strike.
  bool ccActive_ = false;
  float ccStart_ = 0.0f, ccDur_ = 0.0f, ccGlow_ = 0.0f, ccFadeMs_ = 30.0f;
  NoiseTime ccNoise_;
  uint32_t seed_ = 0;
};

// 7 — Faulty bulb. S: glitch speed (x1.5 -> x0.5 durations).
// F: time between glitches 12 s -> 1.5 s.
class FaultyBulbEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  struct Step {
    float level;   // perceptual 0..1
    uint16_t ms;   // unscaled duration
  };
  static constexpr uint8_t kMaxSteps = 40;
  void buildFault(Rng& rng);
  void push(float level, float ms);

  Step steps_[kMaxSteps] = {};
  uint8_t count_ = 0;
  uint8_t idx_ = 0;
  float stepT_ = 0.0f;
  bool faulting_ = false;
  float steadyT_ = 0.0f;
  float steadyFactor_ = 1.0f;
  NoiseTime ripple_;
  uint32_t seed_ = 0;
};

// 8 — Welding. S: weld length (0.3 s tack -> 8 s bead). F: gap between
// welds (0.8 s -> 12 s; higher = longer pause). Scratch-start ignition sparks,
// a living arc (plasma shimmer, short-circuit crackle, spatter pops, hand
// wander and weave), occasional arc outages with re-strike, crater fill, then
// a dim cooling glow with hot-spatter twinkles. Uses the base colour.
class WeldingEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  enum class Phase : uint8_t { Gap, Ignition, Arc, Outage, CraterFill };
  void startWeld(const EffectInput& in);
  void finishWeld(Rng& rng);
  float scheduleSparks(Rng& rng, float startMs, int count);
  float arcLevel(const EffectInput& in, float lenTargetMs);

  Phase phase_ = Phase::Gap;
  float t_ = 0.0f;             // ms in the current phase
  float lenFactor_ = 1.0f;     // per-weld random factors (durations follow live sliders)
  float gapFactor_ = 1.0f;
  float arcMs_ = 0.0f;         // arc time accumulated in this weld
  float catchMs_ = 0.0f;       // ignition / re-strike: arc establishes at this phase time
  float rampMs_ = 0.0f;        // time since the arc (re)established
  float endMs_ = 0.0f;         // crater-fill duration
  bool outagePlanned_ = false;
  float outageFrac_ = 0.5f;
  bool craterPlanned_ = false;
  uint8_t tacksLeft_ = 0;
  bool tackGap_ = false;
  float tackGapMs_ = 0.0f;
  float glow_ = 0.0f;          // perceptual cooling-bead glow
  float glowTauMs_ = 800.0f;
  float dipT_ = 0.0f, dipMs_ = 0.0f, dipDepth_ = 0.0f;  // short-circuit crackle
  float weaveT_ = 0.0f;
  NoiseTime wander_;
  NoiseTime shimmer_;
  uint32_t seed_ = 0;
  PulsePool pulses_;
};

// 9 — Club lights. S: tempo 90 -> 170 BPM. F: energy (pattern density and
// strobe rate). Never pitch black except a rare, <= 120 ms accent blackout.
class ClubEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  enum class Pattern : uint8_t { Hit, Strobe, Chase, Dip, WhiteStrobe };
  void nextBeat(const EffectInput& in);
  LinColor pickColor(const EffectInput& in);

  float beatPhase_ = 0.0f;
  uint8_t beatInBar_ = 0;
  Pattern pattern_ = Pattern::Hit;
  LinColor colorA_ = {1, 0, 1, 0};
  LinColor colorB_ = {0, 0, 1, 0};
  bool blackoutBar_ = false;
  uint8_t lastBucket_ = 0xFF;
};

// 10 — Rainbow. F: full hue cycle 30 s -> 3 s.
class RainbowEffect final : public Effect {
 public:
  void reset(Rng&) override;
  LinColor render(const EffectInput& in) override;

 private:
  float hue_ = 0.0f;
};

// 11 — Fire. S: flicker speed (noise time-scale x0.4 -> x2.5).
// F: flame intensity (flicker depth 15 -> 60 % and flare rate).
class FireEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  NoiseTime t_;
  float flareT_ = 0.0f;
  float flareMs_ = 0.0f;
  float flareGain_ = 0.0f;
  uint32_t seed_ = 0;
};

// 12 — Police strobe. S: flash on-time 150 -> 40 ms (and pause 400 -> 100 ms).
// F: flashes per side 1 -> 6. colorMode 1 = red/blue, 0 = custom A/B.
class PoliceEffect final : public Effect {
 public:
  void reset(Rng&) override;
  LinColor render(const EffectInput& in) override;

 private:
  uint8_t side_ = 0;
  uint8_t flash_ = 0;
  bool on_ = true;
  bool pausing_ = false;
  float t_ = 0.0f;
};

// 13 — Candle. S: flicker speed (noise time-scale x0.4 -> x2.5).
// F: flicker depth 4 -> 35 %. Rare gentle draught dips.
class CandleEffect final : public Effect {
 public:
  void reset(Rng& rng) override;
  LinColor render(const EffectInput& in) override;

 private:
  NoiseTime t_;
  float draughtIn_ = 8000.0f;
  float draughtT_ = 0.0f;
  float draughtMs_ = 0.0f;
  float draughtDepth_ = 0.0f;
  uint32_t seed_ = 0;
};
