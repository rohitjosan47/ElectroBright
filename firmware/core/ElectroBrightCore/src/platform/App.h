#pragma once
// Device wiring: creates the peripherals, the control and render tasks, the
// 200 Hz frame timer and the BLE service. Everything else is portable code.

#include "../fixture/FixtureProfile.h"

namespace App {
// Starts the light as the fixture type stored in it. Without a stored type,
// `buildDefault` is saved and used (a sketch's first install); a build without
// one (FixtureType::None) starts in setup-needed mode. Call once from setup().
void start(FixtureType buildDefault = FixtureType::None);
}
