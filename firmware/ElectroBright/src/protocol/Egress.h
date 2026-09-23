#pragma once
// Outgoing reply buffer.
//
// Reply lines are appended ('\n'-terminated) and later flushed as BLE
// notifications of at most (MTU - 3) bytes. Several short lines share one
// notification (fewer radio packets); a long line may span notifications —
// the app reassembles on '\n'. If the stack refuses a notification (out of
// buffers), the data stays queued and is retried on the next flush. When the
// buffer is full, the OLDEST complete lines are dropped, never partial ones.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "../config/Config.h"

class Egress {
 public:
  // Returns false if the line had to evict older lines (or could not fit).
  bool push(const char* line) {
    const size_t n = strlen(line);
    if (n == 0) return true;
    if (n + 1 > sizeof(buf_)) return false;
    bool evicted = false;
    while (len_ + n + 1 > sizeof(buf_)) {
      dropOldestLine();
      evicted = true;
    }
    memcpy(buf_ + len_, line, n);
    buf_[len_ + n] = '\n';
    len_ += n + 1;
    if (evicted) ++drops_;
    return !evicted;
  }

  // send(const uint8_t* data, size_t len) -> bool. Returns bytes sent.
  template <typename Send>
  size_t flush(size_t maxChunk, Send&& send) {
    if (maxChunk == 0) maxChunk = 20;
    size_t sent = 0;
    while (len_ > 0) {
      const size_t chunk = len_ < maxChunk ? len_ : maxChunk;
      if (!send(reinterpret_cast<const uint8_t*>(buf_), chunk)) {
        ++retries_;
        break;
      }
      memmove(buf_, buf_ + chunk, len_ - chunk);
      len_ -= chunk;
      sent += chunk;
    }
    return sent;
  }

  void clear() { len_ = 0; }
  size_t pending() const { return len_; }
  uint32_t drops() const { return drops_; }
  uint32_t retries() const { return retries_; }

 private:
  void dropOldestLine() {
    const void* nl = memchr(buf_, '\n', len_);
    const size_t cut = nl ? static_cast<size_t>(static_cast<const char*>(nl) - buf_) + 1 : len_;
    memmove(buf_, buf_ + cut, len_ - cut);
    len_ -= cut;
  }

  char buf_[cfg::kEgressBytes] = {};
  size_t len_ = 0;
  uint32_t drops_ = 0;
  uint32_t retries_ = 0;
};
