#pragma once
// The light's active fixture type: one byte (FixtureType) under key "fx" in
// its own NVS namespace (cfg::kSystemNvsNamespace), so FACTORY_RESET, which
// erases the settings / scene / preset namespace, never touches it.
//
// Boot: a stored type wins. Without one, a build with a default type (the
// sketches in firmware/fixtures/) saves and uses it; a build without one
// (FixtureType::None) never invents a type and starts in setup-needed mode.

#include "../state/KeyValueStore.h"
#include "Profiles.h"

namespace fxselect {

constexpr const char* kTypeKey = "fx";

// The stored type; None when absent or not a selectable type.
FixtureType read(IKeyValueStore& system);
bool write(IKeyValueStore& system, FixtureType type);

// The boot decision above; profiles::kNone means setup-needed mode.
const FixtureProfile& select(IKeyValueStore& system, FixtureType buildDefault);

}  // namespace fxselect

// PROBE: which pin a physical output (board::kOutputPins order) is, and which
// layout channel of the active profile drives it (kNoChannel: the output is
// not in the layout, it is one of the parked pins).
namespace probe {

constexpr uint8_t kNoChannel = 0xFF;

struct Route {
  uint8_t pin;
  uint8_t channel;
};

Route route(const FixtureProfile& fixture, uint8_t output);

constexpr uint8_t kNoPin = 0xFF;

// Applies RenderParams::probe (0 = off) to one frame's layout duties: every
// channel off except the probed one, at cfg::kProbeDuty. Returns the pin to
// drive at that duty outside the layout (a parked output), else kNoPin.
uint8_t apply(const FixtureProfile& fixture, uint8_t probe, uint16_t* duty);

}  // namespace probe
