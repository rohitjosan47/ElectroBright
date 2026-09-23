#include "BinaryFrame.h"

namespace binframe {

bool decode(const uint8_t* d, size_t len, ColorFrame& out) {
  if (!isCandidate(d, len)) return false;

  if (len == 8) {
    const uint8_t sum = static_cast<uint8_t>(d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ 0x55);
    if (sum != d[7]) return false;
    out.hasSeq = true;
    out.seq = d[1];
    out.color = {d[2], d[3], d[4], d[5]};
    out.hasBrightness = true;
    out.brightness = d[6];
    return true;
  }
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
  // len == 6
  const uint8_t sum = static_cast<uint8_t>(d[1] ^ d[2] ^ d[3] ^ d[4] ^ 0x55);
  if (sum != d[5]) return false;
  out.hasSeq = false;
  out.seq = 0;
  out.color = {d[1], d[2], d[3], d[4]};
  out.hasBrightness = false;
  out.brightness = 0;
  return true;
}

void encode8(uint8_t seq, const Rgbw8& c, uint8_t br, uint8_t out[8]) {
  out[0] = kMagic;
  out[1] = seq;
  out[2] = c.r;
  out[3] = c.g;
  out[4] = c.b;
  out[5] = c.w;
  out[6] = br;
  out[7] = static_cast<uint8_t>(seq ^ c.r ^ c.g ^ c.b ^ c.w ^ br ^ 0x55);
}

}  // namespace binframe
