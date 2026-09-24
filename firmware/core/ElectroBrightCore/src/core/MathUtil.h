#pragma once
// Small numeric helpers used by the render engine and effects.

#include <math.h>
#include <stdint.h>

#include "../config/Config.h"
#include "Types.h"

namespace mathx {

constexpr float kPi = 3.14159265358979f;

inline float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }
inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline float lerp(float a, float b, float t) { return a + (b - a) * t; }

inline LinColor lerp(const LinColor& a, const LinColor& b, float t) {
  return {lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t), lerp(a.w, b.w, t), lerp(a.ww, b.ww, t)};
}

inline LinColor clamp01(const LinColor& c) {
  return {clamp01(c.r), clamp01(c.g), clamp01(c.b), clamp01(c.w), clamp01(c.ww)};
}

// Slider level 1..10 -> 0.0..1.0 (out-of-range input is clamped).
inline float level01(uint8_t level) {
  if (level < cfg::kMinLevel) level = cfg::kMinLevel;
  if (level > cfg::kMaxLevel) level = cfg::kMaxLevel;
  return static_cast<float>(level - cfg::kMinLevel) / static_cast<float>(cfg::kMaxLevel - cfg::kMinLevel);
}

// Geometric mapping of a 1..10 slider level onto [a, b]: every step is the same
// *relative* change, which is how humans perceive rate and duration.
inline float geo(uint8_t level, float a, float b) { return a * powf(b / a, level01(level)); }

inline float smoothstep(float t) {
  t = clamp01(t);
  return t * t * (3.0f - 2.0f * t);
}

// 0 -> 0, 0.5 -> 1, 1 -> 0 half-cosine bump, used for smooth dips and pulses.
inline float bump(float t) { return 0.5f - 0.5f * cosf(clamp01(t) * 2.0f * kPi); }

// Raised cosine 0 -> 1 over t in [0, 1].
inline float easeInOut(float t) { return 0.5f - 0.5f * cosf(clamp01(t) * kPi); }

// Exponential smoothing coefficient for a one-pole filter.
inline float smoothingAlpha(float dtMs, float tauMs) {
  if (tauMs <= 0.0f) return 1.0f;
  return 1.0f - expf(-dtMs / tauMs);
}

// Wraps a phase in [0, 1).
inline float wrap01(float p) {
  if (p >= 1.0f || p < 0.0f) p -= floorf(p);
  return p;
}

}  // namespace mathx
