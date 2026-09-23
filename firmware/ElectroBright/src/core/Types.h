#pragma once
// Plain value types shared by every layer.

#include <stdint.h>

// 8-bit sRGB-encoded (perceptual) RGBW value as sent by the app.
struct Rgbw8 {
  uint8_t r, g, b, w;
};

inline bool operator==(const Rgbw8& a, const Rgbw8& b) {
  return a.r == b.r && a.g == b.g && a.b == b.b && a.w == b.w;
}
inline bool operator!=(const Rgbw8& a, const Rgbw8& b) { return !(a == b); }

// Linear-light RGBW, each channel 0.0 .. 1.0. The whole render pipeline works
// in this space so blends, fades and envelopes are physically correct.
struct LinColor {
  float r, g, b, w;
};

inline LinColor operator*(const LinColor& c, float k) { return {c.r * k, c.g * k, c.b * k, c.w * k}; }
inline LinColor operator+(const LinColor& a, const LinColor& b) {
  return {a.r + b.r, a.g + b.g, a.b + b.b, a.w + b.w};
}
inline LinColor operator-(const LinColor& a, const LinColor& b) {
  return {a.r - b.r, a.g - b.g, a.b - b.b, a.w - b.w};
}

constexpr LinColor kBlack{0.0f, 0.0f, 0.0f, 0.0f};
