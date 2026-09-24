#include "SceneCodec.h"

namespace scenecodec {

namespace {

bool hasWarm(const ChannelLayout& l) { return layout::has(l, Channel::WW); }

uint8_t* putRgbw(uint8_t* p, const Color8& c) {
  *p++ = c.r;
  *p++ = c.g;
  *p++ = c.b;
  *p++ = c.w;
  return p;
}

const uint8_t* getRgbw(const uint8_t* p, Color8& c) {
  c.r = *p++;
  c.g = *p++;
  c.b = *p++;
  c.w = *p++;
  c.ww = 0;
  return p;
}

}  // namespace

size_t recordSize(const ChannelLayout& l) { return 1 + kLegacyBytes + (hasWarm(l) ? 3 : 0); }

size_t pack(const Scene& s, const ChannelLayout& l, uint8_t* out) {
  uint8_t* p = out;
  *p++ = kSchema;
  p = putRgbw(p, s.color);
  *p++ = s.brightness;
  *p++ = s.mode;
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) *p++ = s.speed[i];
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) *p++ = s.freq[i];
  *p++ = s.fireworkColorMode;
  *p++ = s.clubColorMode;
  *p++ = s.policeColorMode;
  p = putRgbw(p, s.policeA);
  p = putRgbw(p, s.policeB);
  if (hasWarm(l)) {
    *p++ = s.color.ww;
    *p++ = s.policeA.ww;
    *p++ = s.policeB.ww;
  }
  return static_cast<size_t>(p - out);
}

bool unpack(const uint8_t* in, size_t len, const ChannelLayout& l, Scene& out) {
  if (in == nullptr || len != recordSize(l) || in[0] != kSchema) return false;
  Scene s{};
  const uint8_t* p = in + 1;
  p = getRgbw(p, s.color);
  s.brightness = *p++;
  s.mode = *p++;
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) s.speed[i] = *p++;
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) s.freq[i] = *p++;
  s.fireworkColorMode = *p++;
  s.clubColorMode = *p++;
  s.policeColorMode = *p++;
  p = getRgbw(p, s.policeA);
  p = getRgbw(p, s.policeB);
  if (hasWarm(l)) {
    s.color.ww = *p++;
    s.policeA.ww = *p++;
    s.policeB.ww = *p++;
  }
  if (!state::isValid(s, l)) return false;
  out = s;
  return true;
}

}  // namespace scenecodec
