#pragma once
// Single-writer / single-reader sequence lock for publishing a small struct
// from the control task to the render task without blocking either side.
//
// The ESP32-C3 has one core, so the render task (higher priority) can preempt
// the control task in the middle of a write. A classic seqlock reader would
// then spin forever (the writer can never run to finish). tryRead() therefore
// never spins: on a torn read it returns false and the caller keeps its last
// good copy for one more frame.

#include <atomic>
#include <stdint.h>

template <typename T>
class SeqLock {
 public:
  void write(const T& value) {
    const uint32_t s = seq_.load(std::memory_order_relaxed);
    seq_.store(s + 1, std::memory_order_relaxed);  // odd = write in progress
    std::atomic_thread_fence(std::memory_order_release);
    data_ = value;
    std::atomic_thread_fence(std::memory_order_release);
    seq_.store(s + 2, std::memory_order_release);
  }

  // Returns true and fills `out` only when a consistent snapshot was taken.
  bool tryRead(T& out) const {
    const uint32_t s1 = seq_.load(std::memory_order_acquire);
    if (s1 & 1u) return false;
    T copy = data_;
    std::atomic_thread_fence(std::memory_order_acquire);
    const uint32_t s2 = seq_.load(std::memory_order_relaxed);
    if (s1 != s2) return false;
    out = copy;
    return true;
  }

  uint32_t sequence() const { return seq_.load(std::memory_order_acquire); }

 private:
  std::atomic<uint32_t> seq_{0};
  T data_{};
};
