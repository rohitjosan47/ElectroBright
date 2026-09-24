#include "Buzzer.h"

#include <driver/ledc.h>

#include "../config/Config.h"

namespace {
constexpr ledc_mode_t kMode = LEDC_LOW_SPEED_MODE;
constexpr ledc_timer_t kTimer = LEDC_TIMER_1;  // separate from the LED timer
constexpr ledc_channel_t kChannel = LEDC_CHANNEL_4;
constexpr uint32_t kHalfDuty = 1u << (cfg::kBuzzerDutyBits - 1);  // 50 % square wave
}  // namespace

bool Buzzer::begin() {
  ledc_timer_config_t t = {};
  t.speed_mode = kMode;
  t.duty_resolution = static_cast<ledc_timer_bit_t>(cfg::kBuzzerDutyBits);
  t.timer_num = kTimer;
  t.freq_hz = 2000;
  t.clk_cfg = LEDC_AUTO_CLK;
  if (ledc_timer_config(&t) != ESP_OK) return false;

  ledc_channel_config_t c = {};
  c.gpio_num = cfg::kPinBuzzer;
  c.speed_mode = kMode;
  c.channel = kChannel;
  c.intr_type = LEDC_INTR_DISABLE;
  c.timer_sel = kTimer;
  c.duty = 0;
  c.hpoint = 0;
  ok_ = ledc_channel_config(&c) == ESP_OK;
  return ok_;
}

void Buzzer::tone(uint16_t hz) {
  if (!ok_) return;
  if (hz == 0) {
    ledc_set_duty(kMode, kChannel, 0);
    ledc_update_duty(kMode, kChannel);
    return;
  }
  if (hz != hz_) {
    if (ledc_set_freq(kMode, kTimer, hz) != ESP_OK) return;
    hz_ = hz;
  }
  ledc_set_duty(kMode, kChannel, kHalfDuty);
  ledc_update_duty(kMode, kChannel);
}
