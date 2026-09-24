#include "PwmOutput.h"

#include <driver/gpio.h>
#include <driver/ledc.h>

#include "../config/Config.h"

namespace {
constexpr ledc_mode_t kMode = LEDC_LOW_SPEED_MODE;  // the C3 only has low-speed LEDC
constexpr ledc_timer_t kTimer = LEDC_TIMER_0;
constexpr ledc_channel_t kChannels[4] = {LEDC_CHANNEL_0, LEDC_CHANNEL_1, LEDC_CHANNEL_2, LEDC_CHANNEL_3};
constexpr uint8_t kPins[4] = {cfg::kPinRed, cfg::kPinGreen, cfg::kPinBlue, cfg::kPinWhite};
constexpr uint32_t kPeriod = 1u << cfg::kPwmBits;

// Phase-shifted PWM: channel i turns on at i/4 of the period, so the four
// MOSFETs do not all switch at the same instant. That lowers the peak current
// step on the 12/24 V supply (less ripple, less buck-converter noise and EMI).
// The offset is reduced when needed so hpoint + duty never exceeds the period
// (the duty cycle itself is always exact).
uint32_t hpointFor(int ch, uint32_t duty) {
  if (!cfg::kPwmPhaseStagger) return 0;
  uint32_t hp = (kPeriod / 4) * static_cast<uint32_t>(ch);
  if (hp + duty > kPeriod - 1) hp = (duty >= kPeriod - 1) ? 0 : (kPeriod - 1 - duty);
  return hp;
}
}  // namespace

bool PwmOutput::begin() {
  // Belt and braces on top of the 10 k gate pull-downs: drive the pins low
  // before the LEDC routes its signal to them. The output latch is cleared
  // *before* the pin becomes an output, and no internal pull-up is ever
  // enabled (gpio_reset_pin() would briefly enable one on the gate).
  gpio_config_t io = {};
  for (uint8_t pin : kPins) {
    gpio_set_level(static_cast<gpio_num_t>(pin), 0);
    io.pin_bit_mask |= (1ULL << pin);
  }
  io.mode = GPIO_MODE_OUTPUT;
  io.pull_up_en = GPIO_PULLUP_DISABLE;
  io.pull_down_en = GPIO_PULLDOWN_DISABLE;
  io.intr_type = GPIO_INTR_DISABLE;
  gpio_config(&io);
  for (uint8_t pin : kPins) gpio_set_level(static_cast<gpio_num_t>(pin), 0);

  ledc_timer_config_t t = {};
  t.speed_mode = kMode;
  t.duty_resolution = static_cast<ledc_timer_bit_t>(cfg::kPwmBits);
  t.timer_num = kTimer;
  t.freq_hz = cfg::kPwmFreqHz;
  t.clk_cfg = LEDC_AUTO_CLK;
  if (ledc_timer_config(&t) != ESP_OK) return false;

  for (int i = 0; i < 4; ++i) {
    ledc_channel_config_t c = {};
    c.gpio_num = kPins[i];
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

void PwmOutput::write(const uint16_t duty[4]) {
  for (int i = 0; i < 4; ++i) {
    if (duty[i] == last_[i]) continue;
    const uint32_t d = duty[i] > cfg::kPwmMaxDuty ? cfg::kPwmMaxDuty : duty[i];
    // The new duty latches at the next period boundary: no glitch / tearing.
    ledc_set_duty_with_hpoint(kMode, kChannels[i], d, hpointFor(i, d));
    ledc_update_duty(kMode, kChannels[i]);
    last_[i] = duty[i];
  }
}
