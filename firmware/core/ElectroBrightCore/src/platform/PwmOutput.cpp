#include "PwmOutput.h"

#include <driver/gpio.h>
#include <driver/ledc.h>
#include <soc/ledc_struct.h>

#include "../config/Config.h"
#include "PwmPlan.h"

namespace {
constexpr ledc_mode_t kMode = LEDC_LOW_SPEED_MODE;  // the C3 only has low-speed LEDC
constexpr ledc_timer_t kTimer = LEDC_TIMER_0;
constexpr ledc_channel_t kChannels[kMaxChannels] = {LEDC_CHANNEL_0, LEDC_CHANNEL_1, LEDC_CHANNEL_2, LEDC_CHANNEL_3,
                                                    LEDC_CHANNEL_4};
static_assert(cfg::kPwmDitherBits == 4, "the C3 LEDC duty register has 4 fractional bits");

// Phase-shifted PWM (see pwmplan::plan): channel i of n turns on at i/n of the
// period, so the MOSFETs do not all switch at the same instant. That lowers
// the peak current step on the 12/24 V supply (less ripple, less
// buck-converter noise and EMI).
}  // namespace

bool PwmOutput::begin(const FixtureProfile& fixture) {
  count_ = fixture.layout->count;
  // Belt and braces on top of the 10 k gate pull-downs: drive the pins low
  // before the LEDC routes its signal to them. The output latch is cleared
  // *before* the pin becomes an output, and no internal pull-up is ever
  // enabled (gpio_reset_pin() would briefly enable one on the gate).
  // Unfitted outputs (e.g. the W gate on an RGB board) are driven low forever.
  gpio_config_t io = {};
  for (uint8_t i = 0; i < count_ + fixture.parkLowCount; ++i) {
    const uint8_t pin = i < count_ ? fixture.pins[i] : fixture.parkLowPins[i - count_];
    gpio_set_level(static_cast<gpio_num_t>(pin), 0);
    io.pin_bit_mask |= (1ULL << pin);
  }
  io.mode = GPIO_MODE_OUTPUT;
  io.pull_up_en = GPIO_PULLUP_DISABLE;
  io.pull_down_en = GPIO_PULLDOWN_DISABLE;
  io.intr_type = GPIO_INTR_DISABLE;
  gpio_config(&io);
  for (uint8_t i = 0; i < count_ + fixture.parkLowCount; ++i) {
    const uint8_t pin = i < count_ ? fixture.pins[i] : fixture.parkLowPins[i - count_];
    gpio_set_level(static_cast<gpio_num_t>(pin), 0);
  }

  ledc_timer_config_t t = {};
  t.speed_mode = kMode;
  t.duty_resolution = static_cast<ledc_timer_bit_t>(cfg::kPwmBits);
  t.timer_num = kTimer;
  t.freq_hz = cfg::kPwmFreqHz;
  t.clk_cfg = LEDC_USE_APB_CLK;  // 80 MHz: the only source fast enough for 11 bits at ~25 kHz
  if (ledc_timer_config(&t) != ESP_OK) return false;

  for (int i = 0; i < count_; ++i) {
    ledc_channel_config_t c = {};
    c.gpio_num = fixture.pins[i];
    c.speed_mode = kMode;
    c.channel = kChannels[i];
    c.intr_type = LEDC_INTR_DISABLE;
    c.timer_sel = kTimer;
    c.duty = 0;
    c.hpoint = 0;
    if (ledc_channel_config(&c) != ESP_OK) return false;
    last_[i] = 0;
  }
  return true;
}

void PwmOutput::write(const uint16_t* duty) {
  for (int i = 0; i < count_; ++i) {
    if (duty[i] == last_[i]) continue;
    const uint32_t d = duty[i] > cfg::kPwmMaxDuty ? cfg::kPwmMaxDuty : duty[i];
    const pwmplan::Plan p = pwmplan::plan(d, static_cast<uint8_t>(i), count_);
    if (p.kind == pwmplan::Kind::High) {
      // Full output: the pin held high, no switching. ledc_stop sets the
      // idle level before it disables the signal, so it never dips low.
      ledc_stop(kMode, kChannels[i], 1);
    } else {
      // Off is PWM at 0. Every on-time stays within period - 1 (PwmPlan.h).
      ledc_set_duty_with_hpoint(kMode, kChannels[i], p.whole, p.hpoint);
      // The driver only writes whole counts; the duty register's low 4 bits
      // are the hardware's fractional part (dithering): write the full value.
      LEDC.channel_group[kMode].channel[kChannels[i]].duty.duty =
          (static_cast<uint32_t>(p.whole) << cfg::kPwmDitherBits) | p.frac;
      // Latches at the next period boundary (no glitch / tearing), and turns
      // the signal output back on after a held-high stretch.
      ledc_update_duty(kMode, kChannels[i]);
    }
    last_[i] = duty[i];
  }
}
