#pragma once
// LED PWM on the ESP32-C3 LEDC peripheral (25 kHz, 11-bit + 4 dithered
// fractional bits): one channel per output of the fixture's layout, LEDC
// channels 0 .. n-1 on timer 0. PROBE of an output outside the layout borrows
// LEDC channel n + 1 (n is the buzzer's).

#include <stdint.h>

#include "../fixture/FixtureProfile.h"

class PwmOutput {
 public:
  // Configures the timer + channels with every output at 0 %, and holds the
  // fixture's unused outputs low. Call first thing at boot so the MOSFET gates
  // are never left floating or high.
  bool begin(const FixtureProfile& fixture);

  // Drives every LED pin the fixture has or parks low, as plain GPIO (before
  // begin(), while the type is not known yet).
  static void holdLow(const FixtureProfile& fixture);

  // PROBE outside the layout: drives `pin` (a parked output) at
  // cfg::kProbeDuty, or parks it low again for probe::kNoPin. Only acts on a change.
  void probe(uint8_t pin);

  // Applies one duty (0..cfg::kPwmMaxDuty, in 1/16 counts) per layout channel:
  // 0 is off, full output holds the pin high (see PwmPlan.h). Unchanged
  // channels are not touched.
  void write(const uint16_t* duty);

 private:
  uint8_t count_ = 0;
  uint8_t probePin_ = 0xFF;  // probe::kNoPin
  uint16_t last_[kMaxChannels] = {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF};
};
