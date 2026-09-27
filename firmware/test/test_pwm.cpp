// The PWM output plan (platform/PwmPlan.h), checked for every duty and every
// channel of every layout size: full output is the pin held high, and no PWM
// period is ever a full period (the LEDC shows those as off).

#include "config/Config.h"
#include "fixture/ChannelLayout.h"
#include "platform/PwmPlan.h"
#include "TestFramework.h"

using pwmplan::Kind;
using pwmplan::Plan;

namespace {
constexpr uint32_t kPeriod = pwmplan::kPeriod;
constexpr uint32_t kDitherPhases = 1u << cfg::kPwmDitherBits;
constexpr uint32_t kFullWhole = kPeriod - 1u;  // 2047: above it, held high

// On-time (counts) of dither phase [phase] of 16: the fraction adds one
// count in [frac] of every 16 periods.
uint32_t onTime(const Plan& p, uint32_t phase) { return p.whole + (phase < p.frac ? 1u : 0u); }

// Average output in 1/16 counts per period.
uint32_t average(const Plan& p) {
  switch (p.kind) {
    case Kind::Off: return 0;
    case Kind::High: return kPeriod << cfg::kPwmDitherBits;
    case Kind::Pwm: break;
  }
  return (static_cast<uint32_t>(p.whole) << cfg::kPwmDitherBits) + p.frac;
}
}  // namespace

TEST(pwm_plan_every_duty_every_channel) {
  uint32_t bad = 0;
  for (uint8_t count = 1; count <= kMaxChannels; ++count) {
    for (uint8_t ch = 0; ch < count; ++ch) {
      uint32_t prev = 0;
      for (uint32_t d = 0; d <= cfg::kPwmMaxDuty; ++d) {
        const Plan p = pwmplan::plan(d, ch, count);
        // Off exactly at 0; held high exactly above 2047 whole counts.
        const Kind want = d == 0 ? Kind::Off : (d > (kFullWhole << cfg::kPwmDitherBits) ? Kind::High : Kind::Pwm);
        bad += p.kind != want;
        if (p.kind == Kind::Pwm) {
          bad += p.maxOn() > kPeriod - 1u;
          bad += static_cast<uint32_t>(p.hpoint) + p.maxOn() > kPeriod - 1u;
          // Exactly the duty asked for (nothing capped or rescaled).
          bad += average(p) != d;
        }
        // More duty never means less light.
        const uint32_t avg = average(p);
        bad += avg < prev;
        prev = avg;
      }
    }
  }
  CHECK_EQ(bad, 0u);
  CHECK(pwmplan::plan(cfg::kPwmMaxDuty, 0, 4).kind == Kind::High);
}

TEST(pwm_no_duty_gives_a_full_period_on_time_in_any_dither_phase) {
  // The 3.6.1 bug: kPwmMaxDuty asked for 2048 of 2048 counts in 15 of 16
  // periods, which the LEDC outputs as off (full brightness ~1/16).
  uint32_t full = 0;
  for (uint8_t count = 1; count <= kMaxChannels; ++count) {
    for (uint8_t ch = 0; ch < count; ++ch) {
      for (uint32_t d = 0; d <= cfg::kPwmMaxDuty; ++d) {
        const Plan p = pwmplan::plan(d, ch, count);
        if (p.kind != Kind::Pwm) continue;
        for (uint32_t phase = 0; phase < kDitherPhases; ++phase) {
          const uint32_t on = onTime(p, phase);
          full += on >= kPeriod;
          full += p.hpoint + on > kPeriod - 1u;
        }
      }
    }
  }
  CHECK_EQ(full, 0u);
}

TEST(pwm_minimum_duty_is_a_steady_single_count) {
  for (uint8_t count = 1; count <= kMaxChannels; ++count) {
    for (uint8_t ch = 0; ch < count; ++ch) {
      const Plan p = pwmplan::plan(cfg::kPwmMinDuty, ch, count);
      CHECK(p.kind == Kind::Pwm);
      CHECK_EQ(p.whole, 1);
      CHECK_EQ(p.frac, 0);  // no dithering: the same pulse every period
    }
  }
}

TEST(pwm_phase_stagger_is_kept) {
  // Mid-level channels start at i/n of the period.
  for (uint8_t ch = 0; ch < 4; ++ch) {
    CHECK_EQ(pwmplan::plan(8000, ch, 4).hpoint, (kPeriod / 4) * ch);
  }
}
