#include "RenderEngine.h"

#include "../config/Config.h"
#include "../core/MathUtil.h"
#include "ChannelMap.h"
#include "Color.h"

#include <math.h>

RenderEngine::RenderEngine(uint32_t seed, const ChannelLayout& layout, LinColor whiteMix)
    : layout_(layout), whiteMix_(whiteMix), foldWhite_(!layout::has(layout, Channel::W)), rng_(seed) {}

Effect& RenderEngine::effectFor(uint8_t mode) {
  switch (mode) {
    case 2: return blink_;
    case 3: return breath_;
    case 4: return fireworks_;
    case 5: return tv_;
    case 6: return thunder_;
    case 7: return faulty_;
    case 8: return welding_;
    case 9: return club_;
    case 10: return rainbow_;
    case 11: return fire_;
    case 12: return police_;
    case 13: return candle_;
    default: return solid_;
  }
}

EffectInput RenderEngine::makeInput(const RenderParams& p, uint8_t mode, float dtMs) {
  EffectInput in;
  in.base = base_;
  in.policeA = color::linearFrom(p.scene.policeA);
  in.policeB = color::linearFrom(p.scene.policeB);
  const uint8_t idx = static_cast<uint8_t>((mode >= 1 && mode <= cfg::kNumModes ? mode : 1) - 1);
  in.speed = p.scene.speed[idx];
  in.freq = p.scene.freq[idx];
  in.colorMode = state::colorModeFor(p.scene, mode);
  in.dtMs = dtMs;
  in.rng = &rng_;
  return in;
}

uint16_t RenderEngine::toDuty(float v) {
  if (!(v > 0.0f)) return 0;  // also catches NaN
  if (v >= 1.0f) return cfg::kPwmMaxDuty;
  const uint32_t d = static_cast<uint32_t>(v * static_cast<float>(cfg::kPwmMaxDuty) + 0.5f);
  // A channel that is supposed to be on never rounds to off: the lowest
  // slider steps stay visibly lit. Genuine zeros (black colour, brightness 0,
  // dark effect phases, finished fades) are exact 0.0 and turn fully off.
  return static_cast<uint16_t>(d == 0 ? 1 : d);
}

float RenderEngine::approach(float current, float target, float alpha) {
  const float next = current + (target - current) * alpha;
  // Snap when within half a 16-bit step, so exponential tails reach the exact
  // target (e.g. true black) instead of hovering at the minimum duty forever.
  return fabsf(target - next) < (0.5f / 65535.0f) ? target : next;
}

void RenderEngine::frame(const RenderParams& p, uint32_t nowMs, uint16_t* duty) {
  float dt = 0.0f;  // the very first frame starts exactly black
  if (!first_) {
    dt = static_cast<float>(static_cast<uint32_t>(nowMs - lastNow_));
    dt = mathx::clampf(dt, 0.0f, 50.0f);
  }
  lastNow_ = nowMs;

  const uint8_t mode = (p.scene.mode >= 1 && p.scene.mode <= cfg::kNumModes) ? p.scene.mode : 1;
  const LinColor targetBase = color::linearFrom(p.scene.color);
  const float targetBright = color::linearFromByte(p.scene.brightness);

  if (first_) {
    first_ = false;
    base_ = targetBase;
    bright_ = targetBright;
    activeMode_ = prevMode_ = mode;
    effectFor(mode).reset(rng_);
    gain_ = 0.0f;
    booting_ = true;
  } else {
    const float ac = mathx::smoothingAlpha(dt, cfg::kColorTauMs);
    base_ = {approach(base_.r, targetBase.r, ac), approach(base_.g, targetBase.g, ac),
             approach(base_.b, targetBase.b, ac), approach(base_.w, targetBase.w, ac)};
    bright_ = approach(bright_, targetBright, mathx::smoothingAlpha(dt, cfg::kBrightnessTauMs));
  }

  // Mode switch: crossfade from the effect that was on screen.
  if (mode != activeMode_) {
    prevMode_ = activeMode_;
    activeMode_ = mode;
    effectFor(mode).reset(rng_);
    xfadeMs_ = 0.0f;
  }

  // Sleep / wake / boot fade.
  const float targetGain = p.sleeping ? 0.0f : 1.0f;
  const float fadeMs = booting_ ? static_cast<float>(cfg::kBootFadeMs)
                                : static_cast<float>(p.fadeMs > 0 ? p.fadeMs : cfg::kSleepFadeMs);
  const float step = dt / fadeMs;
  if (gain_ < targetGain) {
    gain_ = gain_ + step > targetGain ? targetGain : gain_ + step;
  } else if (gain_ > targetGain) {
    gain_ = gain_ - step < targetGain ? targetGain : gain_ - step;
  }
  if (booting_ && (gain_ >= 1.0f || p.sleeping)) booting_ = false;

  if (gain_ <= 0.0f) {
    // Fully dark: skip effect work entirely.
    lastOut_ = kBlack;
    for (uint8_t i = 0; i < layout_.count; ++i) duty[i] = 0;
    return;
  }

  LinColor out = effectFor(activeMode_).render(makeInput(p, activeMode_, dt));
  if (xfadeMs_ < kXfadeDoneMs) {
    xfadeMs_ += dt;
    if (xfadeMs_ >= cfg::kModeCrossfadeMs || prevMode_ == activeMode_) {
      xfadeMs_ = kXfadeDoneMs;
    } else {
      const LinColor prev = effectFor(prevMode_).render(makeInput(p, prevMode_, dt));
      out = mathx::lerp(prev, out, mathx::smoothstep(xfadeMs_ / cfg::kModeCrossfadeMs));
    }
  }
  out = mathx::clamp01(out);
  lastOut_ = out;

  const float k = bright_ * gain_;
  const LinColor mapped = foldWhite_ ? chanmap::foldWhite(out, whiteMix_) : out;
  for (uint8_t i = 0; i < layout_.count; ++i) duty[i] = toDuty(chanmap::component(mapped, layout_.roles[i]) * k);
}
