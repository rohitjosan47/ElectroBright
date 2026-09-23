#pragma once
// Four-channel LED PWM on the ESP32-C3 LEDC peripheral (14-bit, ~4.9 kHz).

#include <stdint.h>

class PwmOutput {
 public:
  // Configures the timer + channels with every output at 0 %. Call first
  // thing at boot so the MOSFET gates are never left floating or high.
  bool begin();

  // Applies four duties (0..16383). Unchanged channels are not touched.
  void write(const uint16_t duty[4]);

 private:
  uint16_t last_[4] = {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF};
};
