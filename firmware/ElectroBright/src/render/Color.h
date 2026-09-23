#pragma once
// Colour-space helpers: perceptual (app / slider) values <-> linear light.

#include <stdint.h>

#include "../core/Types.h"

namespace color {

// 8-bit perceptual value -> linear 0..1 (exact LUT lookup).
float linearFromByte(uint8_t v);

// Perceptual level 0..1 -> linear 0..1 (LUT with interpolation, so smooth
// envelopes do not show 8-bit steps).
float linearFromLevel(float level);

LinColor linearFrom(const Rgbw8& c);

// HSV (hue in degrees, s/v 0..1, all perceptual) -> linear RGB, W = 0.
LinColor hsvToLinear(float hueDeg, float sat, float val);

}  // namespace color
