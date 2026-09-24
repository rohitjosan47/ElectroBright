#pragma once
// Flash format of a Scene (the live scene and every preset), independent of the
// in-memory struct.
//
//   [schema = 1]
//   [r, g, b, w, brightness, mode, speed x13, freq x13, fwCM, clubCM, policeCM,
//    policeA r, g, b, w, policeB r, g, b, w]              the original 43 bytes
//   [color.ww, policeA.ww, policeB.ww]                     only layouts with WW
//
// Layouts without warm white (RGBW, RGB) therefore store exactly the bytes of
// firmware 3.4.0, so presets survive firmware updates. A record is accepted
// only with the right schema, the exact size for the layout and valid fields.

#include <stddef.h>
#include <stdint.h>

#include "../fixture/ChannelLayout.h"
#include "DeviceState.h"

namespace scenecodec {

constexpr uint8_t kSchema = 1;
constexpr size_t kLegacyBytes = 4 + 1 + 1 + 2 * cfg::kNumModes + 3 + 4 + 4;  // 43
constexpr size_t kMaxRecord = 1 + kLegacyBytes + 3;

size_t recordSize(const ChannelLayout& l);
// Writes recordSize(l) bytes to `out`; returns that size.
size_t pack(const Scene& s, const ChannelLayout& l, uint8_t* out);
// False (and `out` untouched) unless schema, size and every field are valid.
bool unpack(const uint8_t* in, size_t len, const ChannelLayout& l, Scene& out);

}  // namespace scenecodec
