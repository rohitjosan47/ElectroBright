#pragma once
// What one LED channel's PWM does for a duty (0..cfg::kPwmMaxDuty, in 1/16
// counts): portable and pure, so the host tests check every duty.
//
// The LEDC generator cannot produce an on-time of a full period (2^kPwmBits
// counts): the low point then falls on the next period's high point and the
// channel stays low for that period. With dithering, kPwmMaxDuty (2047 whole
// + 15/16) asked for exactly that in 15 of every 16 periods, so full
// brightness collapsed to about 1/16. So:
//   - full output (above period - 1 whole counts) is the pin held high, not
//     PWM: the channel is stopped with its idle level high;
//   - every PWM on-time, dithered count included, is at most period - 1,
//     and hpoint + on-time never passes period - 1 (phase stagger kept).

#include <stdint.h>

#include "../config/Config.h"

namespace pwmplan {

constexpr uint32_t kPeriod = 1u << cfg::kPwmBits;                  // counts per period
constexpr uint32_t kFracMask = (1u << cfg::kPwmDitherBits) - 1u;
// The largest duty PWM carries: period - 1 whole counts, no fraction.
constexpr uint32_t kMaxPwmDuty = (kPeriod - 1u) << cfg::kPwmDitherBits;

enum class Kind : uint8_t { Off, Pwm, High };

struct Plan {
  Kind kind;
  uint16_t whole;   // Pwm: on-time in whole counts
  uint8_t frac;     // Pwm: the dither fraction (one more count in frac of 16 periods)
  uint16_t hpoint;  // Pwm: where the on-time starts in the period

  // The longest on-time of any period (the dithered count included).
  uint32_t maxOn() const { return whole + (frac ? 1u : 0u); }
};

// Channel [ch] of [count] (phase stagger: channel i turns on at i/count of
// the period, moved earlier where the on-time would run past its end).
inline Plan plan(uint32_t duty, uint8_t ch, uint8_t count) {
  if (duty == 0) return {Kind::Off, 0, 0, 0};
  if (duty > kMaxPwmDuty) return {Kind::High, 0, 0, 0};
  Plan p{Kind::Pwm, static_cast<uint16_t>(duty >> cfg::kPwmDitherBits),
         static_cast<uint8_t>(duty & kFracMask), 0};
  if (cfg::kPwmPhaseStagger && count > 0) {
    uint32_t hp = (kPeriod / count) * ch;
    const uint32_t on = p.maxOn();  // <= period - 1 here
    if (hp + on > kPeriod - 1u) hp = kPeriod - 1u - on;
    p.hpoint = static_cast<uint16_t>(hp);
  }
  return p;
}

}  // namespace pwmplan
