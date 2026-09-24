// Mode 9 — Club lights.
//
// A beat clock (tempo from the speed slider) drives one pattern per beat:
//   Hit     colour slam that decays to a dim wash within the beat
//   Strobe  1/16 (or 1/32 at high energy) strobes; "off" = dim wash
//   Chase   two colours alternating on 1/8 (or 1/16) notes
//   Dip     sits on the dim wash, swelling into the next beat
//   White   white-channel strobe
// Energy (frequency slider) shifts the pattern mix towards strobes. The light
// never goes pitch black except a rare accent: ~5 % of bars end with a true
// blackout of at most 120 ms.

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

namespace {
constexpr float kWashLevel = 0.12f;       // perceptual level of the dim wash
constexpr float kBlackoutMaxMs = 120.0f;
constexpr float kBlackoutBarChance = 0.05f;
const LinColor kWhite{1.0f, 0.9f, 0.85f, 1.0f};
}  // namespace

void ClubEffect::reset(Rng& rng) {
  beatPhase_ = 0.0f;
  beatInBar_ = 0;
  blackoutBar_ = false;
  pattern_ = Pattern::Hit;
  (void)rng;
}

LinColor ClubEffect::pickColor(const EffectInput& in) {
  Rng& rng = *in.rng;
  if (in.colorMode == 0) {  // manual: base colour at varying intensity
    return rng.chance(0.5f) ? in.base : in.base * color::linearFromLevel(rng.range(0.35f, 0.7f));
  }
  uint8_t bucket = static_cast<uint8_t>(rng.below(6));
  if (bucket == lastBucket_) bucket = static_cast<uint8_t>(rng.below(6));
  lastBucket_ = bucket;
  switch (bucket) {
    case 0: return color::hsvToLinear(rng.range(300, 331), 1.0f, 1.0f);  // hot pink / magenta
    case 1: return color::hsvToLinear(rng.range(200, 231), 1.0f, 1.0f);  // electric blue
    case 2: return color::hsvToLinear(rng.range(110, 141), 1.0f, 1.0f);  // laser green
    case 3: return color::hsvToLinear(rng.range(260, 281), 1.0f, 1.0f);  // purple
    case 4: return color::hsvToLinear(rng.range(170, 191), 1.0f, 1.0f);  // cyan
    default: return kWhite;
  }
}

void ClubEffect::nextBeat(const EffectInput& in) {
  Rng& rng = *in.rng;
  beatInBar_ = static_cast<uint8_t>((beatInBar_ + 1) & 3);
  if (beatInBar_ == 0) blackoutBar_ = rng.chance(kBlackoutBarChance);

  const float e = mathx::level01(in.freq);
  if (beatInBar_ == 0 && rng.chance(0.6f)) {
    pattern_ = Pattern::Hit;  // downbeats mostly land a hit
  } else {
    const float wHit = 35.0f - 15.0f * e;
    const float wChase = 20.0f;
    const float wDip = 15.0f - 10.0f * e;
    const float wStrobe = 15.0f + 25.0f * e;
    const float wWhite = 5.0f + 10.0f * e;
    float r = rng.unit() * (wHit + wChase + wDip + wStrobe + wWhite);
    if ((r -= wHit) < 0) pattern_ = Pattern::Hit;
    else if ((r -= wChase) < 0) pattern_ = Pattern::Chase;
    else if ((r -= wDip) < 0) pattern_ = Pattern::Dip;
    else if ((r -= wStrobe) < 0) pattern_ = Pattern::Strobe;
    else pattern_ = Pattern::WhiteStrobe;
  }
  colorA_ = pickColor(in);
  colorB_ = pickColor(in);
}

LinColor ClubEffect::render(const EffectInput& in) {
  const float bpm = 90.0f + 80.0f * mathx::level01(in.speed);
  const float beatMs = 60000.0f / bpm;
  const float e = mathx::level01(in.freq);

  beatPhase_ += in.dtMs / beatMs;
  while (beatPhase_ >= 1.0f) {
    beatPhase_ -= 1.0f;
    nextBeat(in);
  }
  const float p = beatPhase_;

  // Accent blackout at the very end of the bar.
  if (blackoutBar_ && beatInBar_ == 3) {
    const float blackoutFrac = mathx::clampf(kBlackoutMaxMs, 0.0f, beatMs * 0.5f) / beatMs;
    if (p >= 1.0f - blackoutFrac) return kBlack;
  }

  const float wash = color::linearFromLevel(kWashLevel);
  switch (pattern_) {
    case Pattern::Hit: {
      const float lvl = p < 0.15f ? 1.0f : wash + (1.0f - wash) * expf(-(p - 0.15f) * 6.0f);
      return colorA_ * lvl;
    }
    case Pattern::Strobe: {
      const float sub = e > 0.6f ? 8.0f : 4.0f;
      const bool on = mathx::wrap01(p * sub) < 0.5f;
      return colorA_ * (on ? 1.0f : wash);
    }
    case Pattern::Chase: {
      const float sub = e > 0.5f ? 4.0f : 2.0f;
      const int step = static_cast<int>(p * sub);
      const float local = mathx::wrap01(p * sub);
      const float lvl = 0.55f + 0.45f * expf(-local * 3.0f);
      return ((step & 1) ? colorB_ : colorA_) * lvl;
    }
    case Pattern::Dip: {
      const float swell = p < 0.75f ? 0.0f : mathx::smoothstep((p - 0.75f) / 0.25f);
      return colorA_ * (wash + (1.0f - wash) * swell);
    }
    case Pattern::WhiteStrobe:
    default: {
      const bool on = mathx::wrap01(p * 8.0f) < 0.5f;
      return kWhite * (on ? 1.0f : wash);
    }
  }
}
