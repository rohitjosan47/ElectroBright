#pragma once
// Reassembles newline-terminated text commands from arbitrarily fragmented
// BLE writes.
//
// Rules (defensive, the sender is not trusted):
//  * '\n', '\r' and "\r\n" all terminate a line; empty lines are ignored.
//  * A line longer than cfg::kMaxLineLength is discarded completely (up to the
//    next terminator). A truncated command is never executed.
//  * A line containing control / non-ASCII bytes is discarded the same way.

#include <stddef.h>
#include <stdint.h>

#include "../config/Config.h"

class LineAssembler {
 public:
  struct Counters {
    uint32_t lines = 0;
    uint32_t overflows = 0;
    uint32_t rejected = 0;
  };

  // Feeds bytes; calls onLine(const char* line, size_t len) for every
  // complete, valid line (NUL-terminated, without the terminator).
  template <typename F>
  void feed(const uint8_t* data, size_t len, F&& onLine) {
    for (size_t i = 0; i < len; ++i) {
      const uint8_t c = data[i];
      if (c == '\n' || c == '\r') {
        finishLine(onLine);
        continue;
      }
      if (state_ != State::Collecting) continue;  // discarding rest of a bad line
      if (c < 0x20 || c >= 0x7F) {
        if (c == '\t') {
          append(' ');
          continue;
        }
        state_ = State::Rejected;
        continue;
      }
      append(static_cast<char>(c));
    }
  }

  void reset() {
    len_ = 0;
    state_ = State::Collecting;
  }

  const Counters& counters() const { return counters_; }

 private:
  enum class State : uint8_t { Collecting, Overflowed, Rejected };

  void append(char c) {
    if (len_ >= cfg::kMaxLineLength) {
      state_ = State::Overflowed;
      return;
    }
    buf_[len_++] = c;
  }

  template <typename F>
  void finishLine(F& onLine) {
    if (state_ == State::Overflowed) {
      ++counters_.overflows;
    } else if (state_ == State::Rejected) {
      ++counters_.rejected;
    } else if (len_ > 0) {
      buf_[len_] = '\0';
      ++counters_.lines;
      onLine(static_cast<const char*>(buf_), static_cast<size_t>(len_));
    }
    reset();
  }

  char buf_[cfg::kMaxLineLength + 1] = {};
  size_t len_ = 0;
  State state_ = State::Collecting;
  Counters counters_;
};
