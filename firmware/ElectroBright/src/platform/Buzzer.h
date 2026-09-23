#pragma once
// Passive piezo buzzer on its own LEDC timer/channel (never disturbs the LED PWM).

#include <stdint.h>

#include "../feedback/SoundSequencer.h"

class Buzzer final : public IToneOutput {
 public:
  bool begin();
  void tone(uint16_t hz) override;  // 0 = silence

 private:
  uint16_t hz_ = 0;
  bool ok_ = false;
};
