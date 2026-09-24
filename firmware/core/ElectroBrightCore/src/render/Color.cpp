#include "Color.h"

#include <math.h>

#include "../core/MathUtil.h"
#include "GammaLut.h"

namespace color {

float linearFromByte(uint8_t v) { return static_cast<float>(kGammaLut16[v]) * (1.0f / 65535.0f); }

float linearFromLevel(float level) {
  level = mathx::clamp01(level);
  const float pos = level * 255.0f;
  int idx = static_cast<int>(pos);
  if (idx >= 255) return 1.0f;
  const float frac = pos - static_cast<float>(idx);
  const float a = static_cast<float>(kGammaLut16[idx]);
  const float b = static_cast<float>(kGammaLut16[idx + 1]);
  return (a + (b - a) * frac) * (1.0f / 65535.0f);
}

LinColor linearFrom(const Color8& c) {
  return {linearFromByte(c.r), linearFromByte(c.g), linearFromByte(c.b), linearFromByte(c.w), linearFromByte(c.ww)};
}

LinColor hsvToLinear(float hueDeg, float sat, float val) {
  sat = mathx::clamp01(sat);
  val = mathx::clamp01(val);
  float h = fmodf(hueDeg, 360.0f);
  if (h < 0.0f) h += 360.0f;
  const float c = val * sat;
  const float hp = h / 60.0f;
  const float x = c * (1.0f - fabsf(fmodf(hp, 2.0f) - 1.0f));
  float r = 0, g = 0, b = 0;
  switch (static_cast<int>(hp)) {
    case 0: r = c; g = x; break;
    case 1: r = x; g = c; break;
    case 2: g = c; b = x; break;
    case 3: g = x; b = c; break;
    case 4: r = x; b = c; break;
    default: r = c; b = x; break;
  }
  const float m = val - c;
  return {linearFromLevel(r + m), linearFromLevel(g + m), linearFromLevel(b + m), 0.0f};
}

}  // namespace color
