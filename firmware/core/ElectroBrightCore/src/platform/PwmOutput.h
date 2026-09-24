#pragma once
// LED PWM on the ESP32-C3 LEDC peripheral (14-bit, ~4.9 kHz): one channel per
// output of the fixture's layout, LEDC channels 0 .. n-1 on timer 0.

#include <stdint.h>

#include "../fixture/FixtureProfile.h"

class PwmOutput {
 public:
  // Configures the timer + channels with every output at 0 %, and holds the
  // fixture's unused outputs low. Call first thing at boot so the MOSFET gates
  // are never left floating or high.
  bool begin(const FixtureProfile& fixture);

  // Applies one duty (0..16383) per layout channel. Unchanged channels are not touched.
  void write(const uint16_t* duty);

 private:
  uint8_t count_ = 0;
  uint16_t last_[kMaxChannels] = {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF};
};
