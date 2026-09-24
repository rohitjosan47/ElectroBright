#pragma once
// Passive piezo buzzer on its own LEDC timer/channel (never disturbs the LED PWM).

#include <driver/ledc.h>
#include <stdint.h>

#include "../feedback/SoundSequencer.h"

class Buzzer final : public IToneOutput {
 public:
  // `channel`: an LEDC channel the LED outputs do not use (the fixture's
  // channel count, so RGBW keeps channel 4).
  bool begin(uint8_t pin, uint8_t channel);
  void tone(uint16_t hz) override;  // 0 = silence

 private:
  ledc_channel_t channel_ = LEDC_CHANNEL_0;
  uint16_t hz_ = 0;
  bool ok_ = false;
};
