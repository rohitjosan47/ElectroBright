#pragma once
// Binary colour fast path (0xAA frames).
//
//   8 bytes (current):  [0xAA, seq, R, G, B, W, Br, seq^R^G^B^W^Br^0x55]
//   7 bytes (legacy):   [0xAA, R, G, B, W, Br, R^G^B^W^Br^0x55]
//   6 bytes (legacy):   [0xAA, R, G, B, W, R^G^B^W^0x55]

#include <stddef.h>
#include <stdint.h>

#include "../core/Types.h"

struct ColorFrame {
  Rgbw8 color;
  uint8_t brightness;
  bool hasBrightness;
  bool hasSeq;
  uint8_t seq;
};

namespace binframe {

constexpr uint8_t kMagic = 0xAA;

// True when the write *looks like* a binary frame (so it must never be fed to
// the text parser, even if its checksum turns out to be bad).
inline bool isCandidate(const uint8_t* data, size_t len) {
  return data != nullptr && len >= 6 && len <= 8 && data[0] == kMagic;
}

// Validates and decodes a frame. Returns false on a bad length or checksum.
bool decode(const uint8_t* data, size_t len, ColorFrame& out);

// Encodes the current 8-byte format (used by tests and tools).
void encode8(uint8_t seq, const Rgbw8& c, uint8_t brightness, uint8_t out[8]);

}  // namespace binframe
