#pragma once
// Replies waiting to be notified on the update control characteristic (the
// stack can be out of buffers for a moment). A few are enough: the app waits
// for each reply before its next request, except ACKs, of which the newest
// is the one that matters.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

class OtaReplies {
 public:
  static constexpr size_t kCapacity = 8;
  static constexpr size_t kMaxLen = 12;

  // Drops the oldest when full.
  void push(const uint8_t* data, size_t len) {
    if (len > kMaxLen) len = kMaxLen;
    if (count_ == kCapacity) pop();
    Entry& e = entries_[(head_ + count_) % kCapacity];
    memcpy(e.data, data, len);
    e.len = static_cast<uint8_t>(len);
    ++count_;
  }
  bool empty() const { return count_ == 0; }
  size_t size() const { return count_; }
  void clear() { head_ = count_ = 0; }

  // Sends in order until `send` refuses one (kept for the next try).
  template <typename Send>
  void flush(Send send) {
    while (count_ > 0) {
      const Entry& e = entries_[head_];
      if (!send(e.data, e.len)) return;
      pop();
    }
  }

 private:
  struct Entry {
    uint8_t data[kMaxLen];
    uint8_t len;
  };
  void pop() {
    head_ = (head_ + 1) % kCapacity;
    --count_;
  }
  Entry entries_[kCapacity] = {};
  size_t head_ = 0;
  size_t count_ = 0;
};
