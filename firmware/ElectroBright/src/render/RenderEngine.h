#pragma once
// Portable render core: turns RenderParams + time into four 14-bit PWM duties.
//
// Pipeline per frame (all in linear light):
//   targets --one-pole smoothing--> base colour / brightness
//   effect(mode) [crossfaded with the previous mode for 300 ms]
//   x master brightness x sleep/boot fade gain  --> 14-bit duty
//
// No heap, no blocking, deterministic for a given seed (host-testable).

#include <stdint.h>

#include "../core/Rng.h"
#include "../core/Types.h"
#include "RenderParams.h"
#include "effects/Effects.h"

class RenderEngine {
 public:
  explicit RenderEngine(uint32_t seed);

  // Renders one frame. `nowMs` may wrap; frame-to-frame dt is clamped to 50 ms.
  void frame(const RenderParams& p, uint32_t nowMs, uint16_t duty[4]);

  // Seeds the effect RNG (the device uses the hardware RNG at boot).
  void reseed(uint32_t seed) { rng_.reseed(seed); }

  float gain() const { return gain_; }
  uint8_t activeMode() const { return activeMode_; }
  bool crossfading() const { return xfadeMs_ < kXfadeDoneMs; }
  LinColor lastOutput() const { return lastOut_; }

 private:
  static constexpr float kXfadeDoneMs = 1e9f;

  Effect& effectFor(uint8_t mode);
  EffectInput makeInput(const RenderParams& p, uint8_t mode, float dtMs);
  static uint16_t toDuty(float v);
  static float approach(float current, float target, float alpha);

  SolidEffect solid_;
  BlinkEffect blink_;
  BreathEffect breath_;
  FireworksEffect fireworks_;
  TvEffect tv_;
  ThunderEffect thunder_;
  FaultyBulbEffect faulty_;
  WeldingEffect welding_;
  ClubEffect club_;
  RainbowEffect rainbow_;
  FireEffect fire_;
  PoliceEffect police_;
  CandleEffect candle_;

  Rng rng_;
  bool first_ = true;
  uint32_t lastNow_ = 0;
  LinColor base_{};
  float bright_ = 0.0f;
  float gain_ = 0.0f;
  bool booting_ = true;
  uint8_t activeMode_ = 1;
  uint8_t prevMode_ = 1;
  float xfadeMs_ = kXfadeDoneMs;
  LinColor lastOut_{};
};
