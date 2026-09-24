#pragma once
// Plain value types shared by every layer.

#include <stdint.h>

// Colour slots shared by every fixture:
//   r, g, b  the RGB LEDs
//   w        the primary white LED (W on RGBW, cool white on RGBCCT)
//   ww       warm white (RGBCCT)
// A fixture's ChannelLayout says which slots physically exist; absent slots
// are always 0 in stored colours.

// 8-bit perceptual (gamma-encoded) colour as sent by the app.
// `ww` defaults to 0, so a 4-value literal means "no warm white".
struct Color8 {
  uint8_t r, g, b, w;
  uint8_t ww = 0;
};

inline bool operator==(const Color8& a, const Color8& b) {
  return a.r == b.r && a.g == b.g && a.b == b.b && a.w == b.w && a.ww == b.ww;
}
inline bool operator!=(const Color8& a, const Color8& b) { return !(a == b); }

// Linear light in the same slots, each 0.0 .. 1.0. The whole render pipeline
// works in this space so blends, fades and envelopes are physically correct.
struct LinColor {
  float r, g, b, w;
  float ww = 0.0f;
};

inline LinColor operator*(const LinColor& c, float k) { return {c.r * k, c.g * k, c.b * k, c.w * k, c.ww * k}; }
inline LinColor operator+(const LinColor& a, const LinColor& b) {
  return {a.r + b.r, a.g + b.g, a.b + b.b, a.w + b.w, a.ww + b.ww};
}
inline LinColor operator-(const LinColor& a, const LinColor& b) {
  return {a.r - b.r, a.g - b.g, a.b - b.b, a.w - b.w, a.ww - b.ww};
}

constexpr LinColor kBlack{0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
