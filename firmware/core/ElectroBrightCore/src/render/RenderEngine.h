#pragma once
// Portable render core: turns RenderParams + time into one PWM duty
// (0..cfg::kPwmMaxDuty) per channel of the fixture's layout.
//
// Pipeline per frame (all in linear light):
//   targets --one-pole smoothing--> base colour / brightness
//   effect(mode) [crossfaded with the previous mode for 300 ms]
//   -> fixture channels (ChannelMap: W folded into RGB on layouts without W)
//   x master brightness x sleep/boot fade gain  --> PWM duty
//   [IDENTIFY overrides the result with full / dark flashes, then lets it through]
//
// No heap, no blocking, deterministic for a given seed (host-testable).

#include <stdint.h>

#include "../config/Config.h"
#include "../core/Rng.h"
#include "../core/Types.h"
#include "../fixture/ChannelLayout.h"
#include "RenderParams.h"
#include "effects/Effects.h"

class RenderEngine {
 public:
  // `whiteMix`: linear RGB standing in for white-channel light when the layout
  // has no W channel (ignored otherwise).
  explicit RenderEngine(uint32_t seed, const ChannelLayout& layout = layouts::kRgbw,
                        LinColor whiteMix = {0.0f, 0.0f, 0.0f, 0.0f});

  // Renders one frame into duty[0 .. layout.count), in layout channel order.
  // `nowMs` may wrap; frame-to-frame dt is clamped to 50 ms.
  void frame(const RenderParams& p, uint32_t nowMs, uint16_t* duty);

  // Output duty scale: full scale and smallest non-zero duty (default: the
  // device PWM). Lets the golden baseline keep its original 14-bit scale.
  void setDutyRange(uint16_t maxDuty, uint16_t minDuty) {
    maxDuty_ = maxDuty;
    minDuty_ = minDuty;
  }

  // Seeds the effect RNG (the device uses the hardware RNG at boot).
  void reseed(uint32_t seed) { rng_.reseed(seed); }

  float gain() const { return gain_; }
  uint8_t activeMode() const { return activeMode_; }
  bool crossfading() const { return xfadeMs_ < kXfadeDoneMs; }
  bool identifying() const { return identifyMs_ < kIdentifyMs; }
  // Last effect output before channel mapping, brightness and fades (linear RGBW).
  LinColor lastOutput() const { return lastOut_; }

 private:
  static constexpr float kXfadeDoneMs = 1e9f;
  static constexpr float kIdentifyPeriodMs = static_cast<float>(cfg::kIdentifyOnMs + cfg::kIdentifyOffMs);
  static constexpr float kIdentifyMs = kIdentifyPeriodMs * cfg::kIdentifyFlashes;

  Effect& effectFor(uint8_t mode);
  EffectInput makeInput(const RenderParams& p, uint8_t mode, float dtMs);
  uint16_t toDuty(float v) const;
  void identifyOverlay(const RenderParams& p, float dtMs, uint16_t* duty);
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

  const ChannelLayout& layout_;
  const LinColor whiteMix_;
  const bool foldWhite_;      // layout has no white LED (neither W nor CW)
  const bool whitesOnly_;     // layout has no colour LED (CCT, W)
  const bool singleWhite_;    // ...and a single white LED (W)

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
  uint16_t maxDuty_ = cfg::kPwmMaxDuty;
  uint16_t minDuty_ = cfg::kPwmMinDuty;
  uint16_t identifyId_ = 0;
  float identifyMs_ = kIdentifyMs;
};
