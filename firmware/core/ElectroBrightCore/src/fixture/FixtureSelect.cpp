#include "FixtureSelect.h"

#include "../config/Config.h"

namespace fxselect {

FixtureType read(IKeyValueStore& system) {
  uint8_t v = 0;
  if (!system.read(kTypeKey, &v, sizeof(v))) return FixtureType::None;
  const FixtureType t = static_cast<FixtureType>(v);
  return profiles::forType(t).type;  // None for anything not in the table
}

bool write(IKeyValueStore& system, FixtureType type) {
  const uint8_t v = static_cast<uint8_t>(type);
  return system.write(kTypeKey, &v, sizeof(v));
}

const FixtureProfile& select(IKeyValueStore& system, FixtureType buildDefault) {
  const FixtureType stored = read(system);
  if (stored != FixtureType::None) return profiles::forType(stored);
  const FixtureProfile& fallback = profiles::forType(buildDefault);
  // A failed write still runs the default; the next boot tries again.
  if (fallback.type != FixtureType::None) write(system, fallback.type);
  return fallback;
}

bool rememberForUpdate(IKeyValueStore& system, FixtureType type) {
  const uint8_t v = static_cast<uint8_t>(type);
  return system.write(kUpdateTypeKey, &v, sizeof(v));
}

bool typeLoaded(IKeyValueStore& system, FixtureType active) {
  uint8_t v = 0;
  if (!system.read(kUpdateTypeKey, &v, sizeof(v))) return true;  // no update to check against
  return v == static_cast<uint8_t>(active);
}

bool forgetUpdate(IKeyValueStore& system) { return system.erase(kUpdateTypeKey); }

}  // namespace fxselect

namespace probe {

Route route(const FixtureProfile& fixture, uint8_t output) {
  Route r{board::kOutputPins[output < board::kNumOutputs ? output : 0], kNoChannel};
  for (uint8_t i = 0; i < fixture.layout->count; ++i) {
    if (fixture.pins[i] == r.pin) r.channel = i;
  }
  return r;
}

uint8_t apply(const FixtureProfile& fixture, uint8_t probe, uint16_t* duty) {
  if (probe == 0 || probe > board::kNumOutputs) return kNoPin;
  const Route r = route(fixture, static_cast<uint8_t>(probe - 1));
  for (uint8_t i = 0; i < fixture.layout->count; ++i) duty[i] = i == r.channel ? cfg::kProbeDuty : 0;
  return r.channel == kNoChannel ? r.pin : kNoPin;
}

}  // namespace probe
