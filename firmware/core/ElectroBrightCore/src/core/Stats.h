#pragma once
// Diagnostic counters, updated from several tasks (hence atomics) and
// reported by the DIAG command.

#include <atomic>
#include <stdint.h>

struct Stats {
  // Ingress
  std::atomic<uint32_t> rxLines{0};
  std::atomic<uint32_t> rxLineOverflows{0};
  std::atomic<uint32_t> rxRejectedBytes{0};
  std::atomic<uint32_t> rxStreamDrops{0};
  std::atomic<uint32_t> unknownCommands{0};
  std::atomic<uint32_t> commandErrors{0};
  std::atomic<uint32_t> coalesced{0};
  std::atomic<uint32_t> binaryOk{0};
  std::atomic<uint32_t> binaryBad{0};
  std::atomic<uint32_t> binarySeqGaps{0};
  // Egress
  std::atomic<uint32_t> notifyRetries{0};
  std::atomic<uint32_t> egressDrops{0};
  // Storage
  std::atomic<uint32_t> nvsWrites{0};
  std::atomic<uint32_t> nvsFailures{0};
  // Render
  std::atomic<uint32_t> renderFrames{0};
  std::atomic<uint32_t> renderOverruns{0};
  std::atomic<uint32_t> renderMaxUs{0};

  static void inc(std::atomic<uint32_t>& c, uint32_t by = 1) { c.fetch_add(by, std::memory_order_relaxed); }
  static void max(std::atomic<uint32_t>& c, uint32_t v) {
    uint32_t cur = c.load(std::memory_order_relaxed);
    while (v > cur && !c.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
    }
  }
  static uint32_t get(const std::atomic<uint32_t>& c) { return c.load(std::memory_order_relaxed); }
};
