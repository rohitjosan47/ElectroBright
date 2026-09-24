// Mode 6 — Thunderstorm.
//
// Goal: every strike should look like a *particular* real lightning strike,
// with its own character, while the storm as a whole stays controlled (steady
// strike rate, a full-power bolt in every strike, darkness in between).
//
// ---------------------------------------------------------------------------
// WHAT REAL LIGHTNING LOOKS LIKE (typical values from high-speed video studies
// of cloud-to-ground flashes)
//   * A flash is a train of return strokes: about 4 on average, anywhere from
//     1 to 10+, and roughly one in five flashes has a single stroke.
//   * The gaps between strokes are irregular (log-normal, typically ~60 ms,
//     from a few ms to a few hundred ms). That uneven stutter is a large part
//     of what makes lightning look like lightning rather than a strobe.
//   * The first stroke is usually the brightest (it is branched and lights up
//     more sky). Later strokes are weaker, but now and then a later stroke
//     finds a new path to ground and is just as bright.
//   * Each stroke is a near-instant spike followed by a quick fall-off, but the
//     channel and the lit clouds keep a dimmer afterglow for tens of ms, so
//     the light has "body" instead of a clean on/off.
//   * In about a third of flashes, one stroke is followed by a continuing
//     current: the channel keeps glowing for 60–500 ms, wavering, with sharp
//     brief re-brightenings riding on it ("M-components").
//   * Sometimes the cloud flickers faintly just before the bolt comes down.
//
// ---------------------------------------------------------------------------
// STROKE MODEL
//   Each stroke is two additive light pulses with an instant rise:
//     fast component  the stroke itself: holds briefly, decays in ~5–16 ms
//     slow component  channel afterglow + scattered cloud light: 8–18 % of
//                     the stroke, decaying in ~25–60 ms
//   The main bolt is larger and longer (it is branched) than later strokes.
//   Pulses are rendered frame-averaged (exact light per 5 ms frame), so even
//   a stroke starting between frames or a sub-frame stutter keeps its true
//   energy and timing. Stroke brightness is chosen in perceptual units, so a
//   "70 % stroke" really looks 70 % as bright as the main bolt.
//
// FIVE STRIKE CHARACTERS
//   Crack    (2 in 10)  one massive bolt, sometimes split into a double hit,
//                       often with one late echo stroke
//   Classic  (3 in 10)  3–5 strokes, main bolt first, the rest fading and
//                       irregularly spaced; now and then a late full-power
//                       "new channel" stroke
//   Stutter  (2 in 10)  5–9 quick strokes, a crackling burst whose brightest
//                       hit may come mid-flash
//   Burner   (2 in 10)  2–4 strokes, then a long wavering continuing current
//                       (200–500 ms) with several M-component flares
//   BuildUp  (1 in 10)  the cloud flickers 2–4 times, faster and brighter,
//                       then the bolt hits, followed by 1–3 aftershocks
//   Characters come from a shuffle bag: exact proportions over every 10
//   strikes and never the same character twice in a row. That gives variety
//   without chaos.
//
// SLIDERS
//   Strike Rate (F): 4 -> 30 strikes per minute (interval 15 s -> 2 s,
//     geometric) with +/-20 % natural spacing. It applies live: the running
//     interval is recomputed from the slider every frame.
//   Stroke Tempo (S): the typical (median) gap between strokes, 160 ms -> 40
//     ms. Individual gaps stay irregular around it. It applies from the next
//     strike (a strike lasts well under 1.5 s).
//
// Light is summed in linear space and multiplied with the user's base colour.
// The room is completely dark between strikes.

#include <math.h>

#include "../../core/MathUtil.h"
#include "../Color.h"
#include "Effects.h"

using mathx::geo;

namespace {
constexpr float kQuietAfterStrikeMs = 300.0f;
constexpr float kTailMs = 170.0f;       // afterglow allowance after the last bright event
constexpr float kReleaseMs = 90.0f;     // final fade into true black
constexpr float kMaxStrikeMs = 1400.0f;

// Tickets per bag of 10: Crack, Classic, Stutter, Burner, BuildUp.
constexpr uint8_t kCharacterTickets[5] = {2, 3, 2, 2, 1};

float strikeIntervalMs(uint8_t freq) { return 60000.0f / geo(freq, 4.0f, 30.0f); }  // 15 s -> 2 s
float medianStrokeGapMs(uint8_t speed) { return geo(speed, 160.0f, 40.0f); }

float gaussian(Rng& rng) {
  const float u1 = fmaxf(rng.unit(), 1e-6f);
  const float u2 = rng.unit();
  return sqrtf(-2.0f * logf(u1)) * cosf(2.0f * mathx::kPi * u2);
}

// Log-normal gap around `median`, clamped so it never collapses or drags on.
float irregularGap(Rng& rng, float median, float sigma) {
  const float lo = fmaxf(12.0f, 0.35f * median);
  return mathx::clampf(median * expf(sigma * gaussian(rng)), lo, 3.0f * median);
}

float linear(float perceptual) { return color::linearFromLevel(perceptual); }
}  // namespace

void ThunderEffect::reset(Rng& rng) {
  seed_ = rng.next();
  pool_.clear();
  bag_.configure(kCharacterTickets);
  flashing_ = false;
  ccActive_ = false;
  quietMs_ = 0.0f;
  sinceStartMs_ = 0.0f;
  jitter_ = 1.0f;
  firstInMs_ = rng.range(300.0f, 900.0f);  // first strike right after selecting the mode
}

ThunderEffect::Stroke ThunderEffect::addStroke(Rng& rng, float at, float perceptual, bool main) {
  const float peak = linear(perceptual);
  // Tuned in perceptual terms: the main bolt reads bright for ~30 ms, then a
  // dim afterglow is gone by ~100 ms; later strokes are shorter still. (The
  // eye compresses brightness, so a 10 % linear tail already looks 35 %
  // bright; longer or stronger tails make the flash look smeared.)
  const float hold = main ? rng.range(12.0f, 20.0f) : rng.range(3.0f, 8.0f);
  const float fastTau = main ? rng.range(10.0f, 16.0f) : rng.range(5.0f, 10.0f);
  const float slowShare = main ? rng.range(0.12f, 0.18f) : rng.range(0.08f, 0.14f);
  const float slowTau = main ? rng.range(35.0f, 60.0f) : rng.range(25.0f, 45.0f);
  pool_.addIn(at, 0.0f, hold, fastTau, peak * (1.0f - slowShare));  // the stroke
  pool_.addIn(at, 0.0f, hold, slowTau, peak * slowShare);           // its afterglow
  return Stroke{at, peak, hold, at + hold + 2.0f * fastTau};
}

ThunderEffect::Stroke ThunderEffect::addStrokeMaybeDoublet(Rng& rng, float at, float perceptual, bool main,
                                                           float doubletChance) {
  Stroke s = addStroke(rng, at, perceptual, main);
  if (rng.chance(doubletChance)) {
    // A second stroke 7–16 ms later: the flash visibly stutters.
    const Stroke d = addStroke(rng, at + rng.range(7.0f, 16.0f), perceptual * rng.range(0.70f, 0.95f), false);
    s.end = fmaxf(s.end, d.end);
  }
  return s;
}

ThunderEffect::Stroke ThunderEffect::aftershocks(Rng& rng, Stroke prev, int count, float medianGapMs, float sigma,
                                                 float doubletChance) {
  for (int k = 0; k < count; ++k) {
    const float gap = fmaxf(irregularGap(rng, medianGapMs, sigma), prev.hold + 8.0f);
    float p = mathx::clampf(rng.range(0.55f, 0.90f) - 0.03f * static_cast<float>(k), 0.45f, 0.92f);
    if (rng.chance(0.12f)) p = 1.0f;  // a later stroke finds a new channel: full power again
    prev = addStrokeMaybeDoublet(rng, prev.at + gap, p, false, doubletChance);
  }
  return prev;
}

float ThunderEffect::startContinuingCurrent(Rng& rng, const Stroke& after, float glowBaseLinear, float durationMs,
                                            int mComponents) {
  ccActive_ = true;
  ccStart_ = after.at + after.hold * 0.5f;  // emerges underneath the stroke's decay
  ccDur_ = durationMs;
  ccGlow_ = glowBaseLinear * rng.range(0.30f, 0.50f);
  ccFadeMs_ = rng.range(25.0f, 45.0f);
  ccNoise_.reset();
  for (int m = 0; m < mComponents; ++m) {
    // M-component: a sharp brief re-brightening of the glowing channel.
    pool_.addIn(ccStart_ + rng.range(0.15f, 0.90f) * durationMs, rng.range(2.0f, 4.0f), rng.range(2.0f, 5.0f),
                rng.range(10.0f, 20.0f), ccGlow_ * rng.range(0.5f, 1.0f));
  }
  return ccStart_ + ccDur_ + 4.0f * ccFadeMs_;
}

float ThunderEffect::continuingCurrent(float t, float dt) {
  if (!ccActive_) return 0.0f;
  const float u = t - ccStart_;
  if (u <= 0.0f) return 0.0f;
  ccNoise_.advance(dt * 0.012f);  // slow ~12 Hz waver
  float body;
  if (u < ccDur_) {
    body = 1.0f - 0.4f * (u / ccDur_);  // slowly weakening glow
  } else {
    body = 0.6f * expf(-(u - ccDur_) / ccFadeMs_);
    if (body < 0.002f) {
      ccActive_ = false;
      return 0.0f;
    }
  }
  const float rise = mathx::clamp01(u / 4.0f);
  const float waver = 1.0f - 0.22f * noise::value(ccNoise_.cell(), ccNoise_.frac(), seed_);
  return ccGlow_ * rise * body * waver;
}

void ThunderEffect::composeStrike(Rng& rng, uint8_t speed) {
  pool_.clear();
  ccActive_ = false;
  strikeT_ = 0.0f;
  const float gap = medianStrokeGapMs(speed);
  character_ = static_cast<Character>(bag_.next(rng));
  ++strikes_;

  float end = 0.0f;  // when the last bright event is over
  switch (character_) {
    case Character::Crack: {
      Stroke last = addStrokeMaybeDoublet(rng, 0.0f, 1.0f, true, 0.30f);
      if (rng.chance(0.4f)) {  // one late echo
        const float at = last.at + fmaxf(irregularGap(rng, 2.0f * gap, 0.3f), last.hold + 8.0f);
        last = addStroke(rng, at, rng.range(0.50f, 0.70f), false);
      }
      end = last.end;
      if (rng.chance(0.25f)) {
        end = fmaxf(end, startContinuingCurrent(rng, last, last.peak, rng.range(60.0f, 150.0f),
                                                static_cast<int>(rng.below(2))));
      }
      break;
    }
    case Character::Classic: {
      const Stroke main = addStrokeMaybeDoublet(rng, 0.0f, 1.0f, true, 0.12f);
      const Stroke last = aftershocks(rng, main, static_cast<int>(2 + rng.below(3)), gap, 0.55f, 0.12f);
      end = last.end;
      if (rng.chance(0.30f)) {
        end = fmaxf(end, startContinuingCurrent(rng, last, last.peak, rng.range(60.0f, 180.0f),
                                                static_cast<int>(rng.below(3))));
      }
      break;
    }
    case Character::Stutter: {
      const int n = static_cast<int>(5 + rng.below(5));
      const int brightest = rng.chance(0.35f) ? static_cast<int>(1 + rng.below(static_cast<uint32_t>(n - 1))) : 0;
      Stroke last{0.0f, 0.0f, 0.0f, 0.0f};
      float at = 0.0f;
      for (int k = 0; k < n; ++k) {
        float p;
        if (k == brightest) {
          p = 1.0f;
        } else if (k == 0) {
          p = rng.range(0.80f, 0.95f);
        } else {
          p = rng.range(0.50f, 0.92f);
        }
        if (k > 0) at = last.at + fmaxf(irregularGap(rng, 0.55f * gap, 0.5f), last.hold + 6.0f);
        last = addStrokeMaybeDoublet(rng, at, p, k == brightest, 0.08f);
      }
      end = last.end;
      if (rng.chance(0.15f)) {
        end = fmaxf(end, startContinuingCurrent(rng, last, last.peak, rng.range(50.0f, 120.0f),
                                                static_cast<int>(rng.below(2))));
      }
      break;
    }
    case Character::Burner: {
      const Stroke main = addStrokeMaybeDoublet(rng, 0.0f, 1.0f, true, 0.12f);
      const Stroke last = aftershocks(rng, main, static_cast<int>(1 + rng.below(3)), gap, 0.55f, 0.10f);
      // The long, wavering glow of a bolt that keeps burning.
      const float base = fmaxf(last.peak, linear(0.85f));
      end = fmaxf(last.end, startContinuingCurrent(rng, last, base, rng.range(200.0f, 500.0f),
                                                   static_cast<int>(2 + rng.below(4))));
      break;
    }
    case Character::BuildUp:
    default: {
      // The cloud flickers faster and brighter, then the bolt comes down.
      const int pre = static_cast<int>(2 + rng.below(3));
      float at = 0.0f;
      float spacing = rng.range(80.0f, 110.0f);
      for (int i = 0; i < pre; ++i) {
        const float p = 0.28f + 0.22f * static_cast<float>(i) / static_cast<float>(pre - 1) + rng.range(-0.03f, 0.03f);
        pool_.addIn(at, 0.0f, rng.range(2.0f, 5.0f), rng.range(6.0f, 10.0f), linear(p));
        at += spacing;
        spacing *= rng.range(0.6f, 0.8f);
      }
      const Stroke main = addStrokeMaybeDoublet(rng, at + rng.range(10.0f, 40.0f), 1.0f, true, 0.15f);
      const Stroke last = aftershocks(rng, main, static_cast<int>(1 + rng.below(3)), gap, 0.55f, 0.10f);
      end = last.end;
      if (rng.chance(0.25f)) {
        end = fmaxf(end, startContinuingCurrent(rng, last, last.peak, rng.range(60.0f, 180.0f),
                                                static_cast<int>(rng.below(3))));
      }
      break;
    }
  }
  strikeEndMs_ = fminf(end + kTailMs, kMaxStrikeMs);
}

LinColor ThunderEffect::render(const EffectInput& in) {
  Rng& rng = *in.rng;
  const float dt = in.dtMs;
  sinceStartMs_ += dt;

  if (!flashing_) {
    if (quietMs_ > 0.0f) quietMs_ -= dt;
    bool start = false;
    if (firstInMs_ > 0.0f) {
      firstInMs_ -= dt;
      start = firstInMs_ <= 0.0f;
    } else {
      start = quietMs_ <= 0.0f && sinceStartMs_ >= strikeIntervalMs(in.freq) * jitter_;
    }
    if (!start) return kBlack;
    composeStrike(rng, in.speed);
    flashing_ = true;
    sinceStartMs_ = 0.0f;
    jitter_ = rng.range(0.8f, 1.2f);
  }

  const float t0 = strikeT_;
  strikeT_ += dt;
  float level = pool_.advanceAveraged(dt) + continuingCurrent(t0 + 0.5f * dt, dt);

  // Final fade into true black once every event (and most of its afterglow) is over.
  const float releaseStart = strikeEndMs_ - kReleaseMs;
  if (strikeT_ > releaseStart) level *= 1.0f - mathx::smoothstep((strikeT_ - releaseStart) / kReleaseMs);
  if (strikeT_ >= strikeEndMs_) {
    flashing_ = false;
    ccActive_ = false;
    pool_.clear();
    quietMs_ = kQuietAfterStrikeMs;
    return kBlack;
  }
  if (level <= 0.0f) return kBlack;
  return in.base * mathx::clamp01(level);
}
