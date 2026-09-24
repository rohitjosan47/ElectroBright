// Core building blocks: shuffle bag (controlled randomness) and the
// frame-averaged light-pulse pool.

#include <math.h>

#include <vector>

#include "core/Rng.h"
#include "core/ShuffleBag.h"
#include "render/effects/Pulses.h"
#include "TestFramework.h"

TEST(shuffle_bag_exact_proportions_per_bag) {
  const uint8_t counts[5] = {2, 3, 2, 2, 1};
  ShuffleBag<5> bag;
  bag.configure(counts);
  Rng rng(99);
  for (int b = 0; b < 200; ++b) {
    int seen[5] = {};
    for (int i = 0; i < 10; ++i) ++seen[bag.next(rng)];
    for (int k = 0; k < 5; ++k) CHECK_EQ(seen[k], counts[k]);
  }
}

TEST(shuffle_bag_never_repeats_consecutively) {
  const uint8_t counts[5] = {2, 3, 2, 2, 1};
  ShuffleBag<5> bag;
  bag.configure(counts);
  Rng rng(7);
  uint8_t last = bag.next(rng);
  int repeats = 0;
  for (int i = 0; i < 5000; ++i) {
    const uint8_t v = bag.next(rng);
    repeats += v == last;
    last = v;
  }
  CHECK_EQ(repeats, 0);
}

TEST(shuffle_bag_order_is_not_fixed) {
  const uint8_t counts[5] = {2, 3, 2, 2, 1};
  ShuffleBag<5> a, b;
  a.configure(counts);
  b.configure(counts);
  Rng ra(1), rb(2);
  int differences = 0;
  for (int i = 0; i < 100; ++i) differences += a.next(ra) != b.next(rb);
  CHECK(differences > 30);  // different seeds give different sequences
}

TEST(pulse_pool_averaged_conserves_energy) {
  // Integral of attack + hold + decay = peak * (a/2 + h + tau).
  PulsePool pool;
  pool.addIn(2.3f, 4.0f, 6.0f, 12.0f, 0.8f);
  const double expected = 0.8 * (4.0 / 2 + 6.0 + 12.0);
  double energy = 0;
  for (int i = 0; i < 100 && !(pool.idle() && i > 5); ++i) energy += pool.advanceAveraged(5.0f) * 5.0;
  CHECK_NEAR(energy, expected, expected * 0.01);
  CHECK(pool.idle());
}

TEST(pulse_pool_averaged_keeps_sub_frame_spikes) {
  // A 2 ms spike inside one 5 ms frame: point sampling at the frame end would
  // miss most of it; the averaged reading shows its true energy.
  PulsePool sampled, averaged;
  sampled.addIn(1.0f, 0.0f, 2.0f, 0.2f, 1.0f);
  averaged.addIn(1.0f, 0.0f, 2.0f, 0.2f, 1.0f);
  const float s = sampled.advance(5.0f);          // 2 ms after the spike ended: e^-10
  const float a = averaged.advanceAveraged(5.0f);  // (2 ms hold + 0.2 ms decay) / 5 ms
  CHECK(s < 0.01f);
  CHECK_NEAR(a, (2.0 + 0.2) / 5.0, 0.02);
}

TEST(pulse_pool_averaged_places_edges_exactly) {
  // A pulse starting 2.5 ms into a frame lights exactly half of that frame.
  PulsePool pool;
  pool.addIn(2.5f, 0.0f, 50.0f, 10.0f, 1.0f);
  CHECK_NEAR(pool.advanceAveraged(5.0f), 0.5, 1e-4);
  CHECK_NEAR(pool.advanceAveraged(5.0f), 1.0, 1e-4);
}
