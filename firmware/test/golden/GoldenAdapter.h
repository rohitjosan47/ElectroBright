#pragma once
// Golden-baseline adapter: the ONLY file under test/golden/ that may change when
// the core API changes. Scenarios.cpp talks to the firmware exclusively through
// this header, so the recorded behaviour of firmware v3.4.0 (RGBW) can be
// replayed unchanged against every later refactor of the shared core.

#include <stdint.h>

#include <memory>
#include <vector>

#include "protocol/BinaryFrame.h"
#include "render/RenderEngine.h"
#include "state/DeviceState.h"
#include "../fwsim/SimDevice.h"
#include "state/SceneCodec.h"

namespace golden {

// Output channels of the fixture under test (RGBW).
constexpr int kChannels = 4;

inline Scene defaultScene() { return state::defaultScene(profiles::kRgbw.defaults); }

class Engine {
 public:
  // Duties on the v3.4.0 PWM scale (14-bit, minimum 1): the baseline pins the
  // rendering, not the PWM resolution (25 kHz / 11-bit + dither since 3.6.1).
  explicit Engine(uint32_t seed) : engine_(seed) { engine_.setDutyRange(16383, 1); }
  void frame(const RenderParams& p, uint32_t nowMs, uint16_t* duty) { engine_.frame(p, nowMs, duty); }

 private:
  RenderEngine engine_;
};

// A scene as the 43 bytes of the original (v3.4.0) struct layout.
inline std::vector<uint8_t> sceneBytes(const Scene& s) {
  uint8_t rec[scenecodec::kMaxRecord];
  const size_t n = scenecodec::pack(s, layouts::kRgbw, rec);
  return std::vector<uint8_t>(rec + 1, rec + n);
}

inline std::unique_ptr<SimDevice> makeDevice() { return std::make_unique<SimDevice>(); }

// Current 8-byte binary colour frame.
inline void encodeFrame(uint8_t seq, const Color8& c, uint8_t brightness, uint8_t out[8]) {
  binframe::encode8(seq, c, brightness, out);
}

}  // namespace golden
