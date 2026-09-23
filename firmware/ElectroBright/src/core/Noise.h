#pragma once
// Smooth 1-D value noise and fractal (fBm) noise for organic effects
// (fire, candle, TV flicker, faulty-bulb ripple).
//
// Time is kept as an integer lattice cell plus a fractional part, so the
// noise stays precise no matter how long the device runs (a plain float
// time would lose resolution after a few hours and start to stutter).

#include <math.h>
#include <stdint.h>

class NoiseTime {
 public:
  void advance(float cells) {
    frac_ += cells;
    if (frac_ >= 1.0f) {
      const float whole = floorf(frac_);
      cell_ += static_cast<uint32_t>(whole);
      frac_ -= whole;
    }
  }
  uint32_t cell() const { return cell_; }
  float frac() const { return frac_; }
  void reset() { cell_ = 0; frac_ = 0.0f; }

 private:
  uint32_t cell_ = 0;
  float frac_ = 0.0f;
};

namespace noise {

inline uint32_t hash32(uint32_t x) {
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  x ^= x >> 16;
  return x;
}

// Pseudo-random value in [0, 1] for a lattice point.
inline float lattice(uint32_t i, uint32_t seed) {
  return static_cast<float>(hash32(i * 0x9E3779B1u ^ seed) >> 8) * (1.0f / 16777215.0f);
}

// Smooth value noise in [0, 1] at (cell + frac).
inline float value(uint32_t cell, float frac, uint32_t seed) {
  const float u = frac * frac * (3.0f - 2.0f * frac);
  const float a = lattice(cell, seed);
  const float b = lattice(cell + 1u, seed);
  return a + (b - a) * u;
}

// Fractal noise in [0, 1]: `octaves` layers, each twice the frequency and half
// the amplitude of the previous one.
inline float fbm(const NoiseTime& t, uint32_t seed, int octaves = 3) {
  float sum = 0.0f;
  float amp = 0.5f;
  float norm = 0.0f;
  uint32_t mul = 1;
  for (int o = 0; o < octaves; ++o) {
    const float scaled = t.frac() * static_cast<float>(mul);
    const float whole = floorf(scaled);
    const uint32_t cell = t.cell() * mul + static_cast<uint32_t>(whole);
    sum += amp * value(cell, scaled - whole, seed + static_cast<uint32_t>(o) * 0x632BE5ABu);
    norm += amp;
    amp *= 0.5f;
    mul <<= 1;
  }
  return sum / norm;
}

}  // namespace noise
