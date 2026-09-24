#pragma once
// Channel layouts: which LED channels a fixture physically has, in wire order.
//
// Inside the core every colour is RGBW (Rgbw8 in scenes and presets, LinColor
// while rendering), so all effects are shared by every fixture. A layout says
// which of those channels exist, which fixes
//   * how many values a colour has on the wire (COLOR, POLICE_COLOR_A/B, the
//     binary frame and STATUS all carry exactly `count` channel values), and
//   * which outputs the rendered colour drives.
// A channel the layout lacks is always 0 in stored colours.

#include <stdint.h>

#include <initializer_list>

#include "../core/Types.h"

enum class Channel : uint8_t { R, G, B, W };

// Upper bound for every per-channel array (sized for future RGB+CW+WW fixtures).
constexpr uint8_t kMaxChannels = 5;

struct ChannelLayout {
  const char* name;  // CAPS LAYOUT value and model-id segment, e.g. "RGBW"
  uint8_t count;     // channels on the wire and on the board
  Channel roles[kMaxChannels];
};

namespace layouts {
inline constexpr ChannelLayout kRgbw{"RGBW", 4, {Channel::R, Channel::G, Channel::B, Channel::W}};
inline constexpr ChannelLayout kRgb{"RGB", 3, {Channel::R, Channel::G, Channel::B}};
}  // namespace layouts

namespace layout {

inline bool has(const ChannelLayout& l, Channel c) {
  for (uint8_t i = 0; i < l.count; ++i) {
    if (l.roles[i] == c) return true;
  }
  return false;
}

inline uint8_t& channelRef(Rgbw8& c, Channel ch) {
  switch (ch) {
    case Channel::R: return c.r;
    case Channel::G: return c.g;
    case Channel::B: return c.b;
    case Channel::W: break;
  }
  return c.w;
}

inline uint8_t channel(const Rgbw8& c, Channel ch) {
  switch (ch) {
    case Channel::R: return c.r;
    case Channel::G: return c.g;
    case Channel::B: return c.b;
    case Channel::W: break;
  }
  return c.w;
}

// Scene colour -> the layout's `count` wire values.
inline void toTuple(const ChannelLayout& l, const Rgbw8& c, uint8_t* out) {
  for (uint8_t i = 0; i < l.count; ++i) out[i] = channel(c, l.roles[i]);
}

// `count` wire values (already range-checked 0..255) -> scene colour; channels
// the layout lacks are 0.
inline Rgbw8 fromTuple(const ChannelLayout& l, const int32_t* v) {
  Rgbw8 c{0, 0, 0, 0};
  for (uint8_t i = 0; i < l.count; ++i) channelRef(c, l.roles[i]) = static_cast<uint8_t>(v[i]);
  return c;
}
inline Rgbw8 fromTuple(const ChannelLayout& l, const uint8_t* v) {
  int32_t w[kMaxChannels] = {};
  for (uint8_t i = 0; i < l.count; ++i) w[i] = v[i];
  return fromTuple(l, w);
}

// True when every channel the layout lacks is 0 (validates stored colours).
inline bool fits(const ChannelLayout& l, const Rgbw8& c) {
  for (Channel ch : {Channel::R, Channel::G, Channel::B, Channel::W}) {
    if (!has(l, ch) && channel(c, ch) != 0) return false;
  }
  return true;
}

}  // namespace layout
