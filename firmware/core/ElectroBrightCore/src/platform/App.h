#pragma once
// Device wiring: creates the peripherals, the control and render tasks, the
// 200 Hz frame timer and the BLE service. Everything else is portable code.

#include "../fixture/FixtureProfile.h"

namespace App {
// Starts the fixture described by `fixture` (copied; call once from setup()).
void start(const FixtureProfile& fixture);
}
