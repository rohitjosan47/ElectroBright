#pragma once
// Binary colour fast path (0xAA frames). A frame carries one value per channel
// of the fixture's layout (n channels):
//
//   n+4 bytes:  [0xAA, seq, c1 .. cn, Br, cs]    cs = seq^c1^..^cn^Br^salt
//               salt = 0x55 for 4-channel layouts, 0x55^n otherwise
//
//   RGBW (n = 4):            [0xAA, seq, R, G, B, W, Br, seq^R^G^B^W^Br^0x55]
//   RGB  (n = 3):            [0xAA, seq, R, G, B, Br, seq^R^G^B^Br^0x56]
//   legacy RGBW, 7 bytes:    [0xAA, R, G, B, W, Br, R^G^B^W^Br^0x55]
//   legacy RGBW, 6 bytes:    [0xAA, R, G, B, W, R^G^B^W^0x55]
//
// The per-layout salt makes a frame for one layout fail the checksum on
// another (e.g. a legacy 7-byte RGBW frame sent to an RGB fixture), so a wrong
// app can never set a wrong colour.

#include <stddef.h>
#include <stdint.h>

#include "../core/Types.h"
#include "../fixture/ChannelLayout.h"

struct ColorFrame {
  Rgbw8 color;
  uint8_t brightness;
  bool hasBrightness;
  bool hasSeq;
  uint8_t seq;
};

namespace binframe {

constexpr uint8_t kMagic = 0xAA;
constexpr size_t kMaxFrame = kMaxChannels + 4;

inline size_t frameLength(const ChannelLayout& l) { return static_cast<size_t>(l.count) + 4; }
inline uint8_t salt(const ChannelLayout& l) { return l.count == 4 ? 0x55 : static_cast<uint8_t>(0x55 ^ l.count); }

// True when the write *looks like* a binary frame, so it must never be fed to
// the text parser, even if it then fails to decode. Covers the 6..8 byte range
// of the original protocol plus the layout's own length.
inline bool isCandidate(const uint8_t* data, size_t len, const ChannelLayout& l) {
  const size_t n = frameLength(l);
  const size_t lo = n < 6 ? n : 6;
  const size_t hi = n > 8 ? n : 8;
  return data != nullptr && len >= lo && len <= hi && data[0] == kMagic;
}

// Validates and decodes a frame for the layout (`legacy`: also the pre-3.x
// 7- and 6-byte RGBW frames). Returns false on a bad length or checksum.
bool decode(const uint8_t* data, size_t len, const ChannelLayout& l, bool legacy, ColorFrame& out);

// Encodes the layout's current frame into out[0 .. frameLength(l)); returns the length.
size_t encode(uint8_t seq, const ChannelLayout& l, const Rgbw8& c, uint8_t brightness, uint8_t* out);

// RGBW shorthands (the original fixture; used by tests and tools).
inline bool isCandidate(const uint8_t* data, size_t len) { return isCandidate(data, len, layouts::kRgbw); }
inline bool decode(const uint8_t* data, size_t len, ColorFrame& out) {
  return decode(data, len, layouts::kRgbw, true, out);
}
inline void encode8(uint8_t seq, const Rgbw8& c, uint8_t brightness, uint8_t out[8]) {
  encode(seq, layouts::kRgbw, c, brightness, out);
}

}  // namespace binframe
