#pragma once
// Fast, tiny PRNG (xorshift32). Seeded from the hardware RNG on the device and
// from a fixed seed in host tests (deterministic simulations).

#include <stdint.h>

class Rng {
 public:
  explicit Rng(uint32_t seed = 0x2545F491u) { reseed(seed); }

  void reseed(uint32_t seed) { state_ = seed ? seed : 0x2545F491u; }

  uint32_t next() {
    uint32_t x = state_;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state_ = x;
    return x;
  }

  // Uniform integer in [0, n) without modulo bias (Lemire multiply-shift).
  uint32_t below(uint32_t n) { return n == 0 ? 0 : static_cast<uint32_t>((static_cast<uint64_t>(next()) * n) >> 32); }

  // Uniform float in [0, 1).
  float unit() { return static_cast<float>(next() >> 8) * (1.0f / 16777216.0f); }

  // Uniform float in [lo, hi).
  float range(float lo, float hi) { return lo + (hi - lo) * unit(); }

  bool chance(float p) { return unit() < p; }

 private:
  uint32_t state_;
};
