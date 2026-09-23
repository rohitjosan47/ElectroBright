#pragma once
// Controlled randomness: a "shuffle bag".
//
// Items are drawn without replacement from a bag that holds a fixed number of
// tickets per item; when the bag is empty it is refilled. Over every bag the
// proportions are therefore exact (no long streaks, no item missing for long),
// while the order stays unpredictable. In addition, the same item is never
// drawn twice in a row: each draw only considers items that keep the rest of
// the bag arrangeable without an adjacent repeat, weighted by their remaining
// tickets.

#include <stdint.h>

#include "Rng.h"

template <uint8_t kItems>
class ShuffleBag {
 public:
  // counts[i] = tickets for item i per bag. No item may hold more than half
  // of the bag (rounded up), otherwise repeats become unavoidable.
  void configure(const uint8_t (&counts)[kItems]) {
    for (uint8_t i = 0; i < kItems; ++i) counts_[i] = counts[i];
    refill();
    last_ = kNone;
  }

  uint8_t next(Rng& rng) {
    if (remaining() == 0) refill();
    const uint8_t n = remaining();

    uint8_t weights[kItems];
    uint32_t total = 0;
    for (uint8_t i = 0; i < kItems; ++i) {
      weights[i] = (left_[i] > 0 && i != last_ && arrangeableAfter(i, n)) ? left_[i] : 0;
      total += weights[i];
    }

    uint8_t pick = 0;
    if (total == 0) {
      // Only reachable with a degenerate configuration: take any ticket left.
      while (left_[pick] == 0) ++pick;
    } else {
      uint32_t r = rng.below(total);
      for (uint8_t i = 0; i < kItems; ++i) {
        if (r < weights[i]) {
          pick = i;
          break;
        }
        r -= weights[i];
      }
    }
    --left_[pick];
    last_ = pick;
    return pick;
  }

  uint8_t remaining() const {
    uint8_t n = 0;
    for (uint8_t i = 0; i < kItems; ++i) n = static_cast<uint8_t>(n + left_[i]);
    return n;
  }

 private:
  static constexpr uint8_t kNone = 0xFF;

  // After drawing `c` from `n` tickets, can the remaining n-1 be ordered with
  // no two equal neighbours (and not starting with `c`)? True iff every item
  // fits into the alternate slots: at most ceil(m/2), or floor(m/2) for `c`.
  bool arrangeableAfter(uint8_t c, uint8_t n) const {
    const uint8_t m = static_cast<uint8_t>(n - 1);
    for (uint8_t y = 0; y < kItems; ++y) {
      const uint8_t count = static_cast<uint8_t>(left_[y] - (y == c ? 1 : 0));
      const uint8_t limit = (y == c) ? static_cast<uint8_t>(m / 2) : static_cast<uint8_t>((m + 1) / 2);
      if (count > limit) return false;
    }
    return true;
  }

  void refill() {
    for (uint8_t i = 0; i < kItems; ++i) left_[i] = counts_[i];
  }

  uint8_t counts_[kItems] = {};
  uint8_t left_[kItems] = {};
  uint8_t last_ = kNone;
};
