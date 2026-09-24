#pragma once
// Channel layouts: which LED channels a fixture physically has, in wire order.
//
// Inside the core every colour has the same five slots (Color8 in scenes and
// presets, LinColor while rendering: r, g, b, w, ww; see core/Types.h), so all
// effects are shared by every fixture. A layout says which LEDs exist and which
// slot drives each one, which fixes
//   * how many values a colour has on the wire (COLOR, POLICE_COLOR_A/B, the
//     binary frame and STATUS all carry exactly `count` channel values), and
//   * which outputs the rendered colour drives.
// A channel the layout lacks is always 0 in stored colours.

#include <stdint.h>

#include <initializer_list>

#include "../core/Types.h"

// Physical LED channels. W and CW both use the `w` slot (the fixture's primary
// white LED); WW uses `ww`.
enum class Channel : uint8_t { R, G, B, W, CW, WW };

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
inline constexpr ChannelLayout kRgbcct{"RGBCCT", 5, {Channel::R, Channel::G, Channel::B, Channel::CW, Channel::WW}};
inline constexpr ChannelLayout kCct{"CCT", 2, {Channel::CW, Channel::WW}};
}  // namespace layouts

namespace layout {

inline bool has(const ChannelLayout& l, Channel c) {
  for (uint8_t i = 0; i < l.count; ++i) {
    if (l.roles[i] == c) return true;
  }
  return false;
}

inline uint8_t& channelRef(Color8& c, Channel ch) {
  switch (ch) {
    case Channel::R: return c.r;
    case Channel::G: return c.g;
    case Channel::B: return c.b;
    case Channel::WW: return c.ww;
    case Channel::W:
    case Channel::CW: break;
  }
  return c.w;
}

inline uint8_t channel(const Color8& c, Channel ch) {
  switch (ch) {
    case Channel::R: return c.r;
    case Channel::G: return c.g;
    case Channel::B: return c.b;
    case Channel::WW: return c.ww;
    case Channel::W:
    case Channel::CW: break;
  }
  return c.w;
}

// True when the layout has an LED on the `w` slot (W or CW).
inline bool hasPrimaryWhite(const ChannelLayout& l) { return has(l, Channel::W) || has(l, Channel::CW); }

// True when the layout has any colour (R, G or B) LED.
inline bool hasColour(const ChannelLayout& l) {
  return has(l, Channel::R) || has(l, Channel::G) || has(l, Channel::B);
}

// Scene colour -> the layout's `count` wire values.
inline void toTuple(const ChannelLayout& l, const Color8& c, uint8_t* out) {
  for (uint8_t i = 0; i < l.count; ++i) out[i] = channel(c, l.roles[i]);
}

// `count` wire values (already range-checked 0..255) -> scene colour; channels
// the layout lacks are 0.
inline Color8 fromTuple(const ChannelLayout& l, const int32_t* v) {
  Color8 c{0, 0, 0, 0};
  for (uint8_t i = 0; i < l.count; ++i) channelRef(c, l.roles[i]) = static_cast<uint8_t>(v[i]);
  return c;
}
inline Color8 fromTuple(const ChannelLayout& l, const uint8_t* v) {
  int32_t w[kMaxChannels] = {};
  for (uint8_t i = 0; i < l.count; ++i) w[i] = v[i];
  return fromTuple(l, w);
}

// True when every slot the layout has no LED for is 0 (validates stored colours).
inline bool fits(const ChannelLayout& l, const Color8& c) {
  for (Channel ch : {Channel::R, Channel::G, Channel::B}) {
    if (!has(l, ch) && channel(c, ch) != 0) return false;
  }
  if (!hasPrimaryWhite(l) && c.w != 0) return false;
  return has(l, Channel::WW) || c.ww == 0;
}

}  // namespace layout
