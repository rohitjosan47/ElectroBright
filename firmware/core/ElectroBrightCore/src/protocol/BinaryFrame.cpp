#include "BinaryFrame.h"

namespace binframe {

namespace {

// Pre-3.x RGBW frames without a sequence number.
bool decodeLegacy(const uint8_t* d, size_t len, ColorFrame& out) {
  if (len == 7) {
    const uint8_t sum = static_cast<uint8_t>(d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ 0x55);
    if (sum != d[6]) return false;
    out.hasSeq = false;
    out.seq = 0;
    out.color = {d[1], d[2], d[3], d[4]};
    out.hasBrightness = true;
    out.brightness = d[5];
    return true;
  }
  if (len == 6) {
    const uint8_t sum = static_cast<uint8_t>(d[1] ^ d[2] ^ d[3] ^ d[4] ^ 0x55);
    if (sum != d[5]) return false;
    out.hasSeq = false;
    out.seq = 0;
    out.color = {d[1], d[2], d[3], d[4]};
    out.hasBrightness = false;
    out.brightness = 0;
    return true;
  }
  return false;
}

}  // namespace

bool decode(const uint8_t* d, size_t len, const ChannelLayout& l, bool legacy, ColorFrame& out) {
  if (!isCandidate(d, len, l)) return false;

  const size_t n = frameLength(l);
  if (len == n) {
    uint8_t sum = salt(l);
    for (size_t i = 1; i + 1 < n; ++i) sum = static_cast<uint8_t>(sum ^ d[i]);
    if (sum != d[n - 1]) return false;
    out.hasSeq = true;
    out.seq = d[1];
    out.color = layout::fromTuple(l, d + 2);
    out.hasBrightness = true;
    out.brightness = d[n - 2];
    return true;
  }
  return legacy && l.count == 4 && decodeLegacy(d, len, out);
}

size_t encode(uint8_t seq, const ChannelLayout& l, const Rgbw8& c, uint8_t br, uint8_t* out) {
  const size_t n = frameLength(l);
  out[0] = kMagic;
  out[1] = seq;
  layout::toTuple(l, c, out + 2);
  out[n - 2] = br;
  uint8_t sum = salt(l);
  for (size_t i = 1; i + 1 < n; ++i) sum = static_cast<uint8_t>(sum ^ out[i]);
  out[n - 1] = sum;
  return n;
}

}  // namespace binframe
