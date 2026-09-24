#pragma once
// Golden-baseline adapter: the ONLY file under test/golden/ that may change when
// the core API changes. Scenarios.cpp talks to the firmware exclusively through
// this header, so the recorded behaviour of firmware v3.4.0 (RGBW) can be
// replayed unchanged against every later refactor of the shared core.

#include <stdint.h>

#include <memory>

#include "protocol/BinaryFrame.h"
#include "render/RenderEngine.h"
#include "state/DeviceState.h"
#include "../fwsim/SimDevice.h"

namespace golden {

// Output channels of the fixture under test (RGBW).
constexpr int kChannels = 4;

inline Scene defaultScene() { return state::defaultScene(); }

class Engine {
 public:
  explicit Engine(uint32_t seed) : engine_(seed) {}
  void frame(const RenderParams& p, uint32_t nowMs, uint16_t* duty) { engine_.frame(p, nowMs, duty); }

 private:
  RenderEngine engine_;
};

inline std::unique_ptr<SimDevice> makeDevice() { return std::make_unique<SimDevice>(); }

// Current 8-byte binary colour frame.
inline void encodeFrame(uint8_t seq, const Rgbw8& c, uint8_t brightness, uint8_t out[8]) {
  binframe::encode8(seq, c, brightness, out);
}

}  // namespace golden
