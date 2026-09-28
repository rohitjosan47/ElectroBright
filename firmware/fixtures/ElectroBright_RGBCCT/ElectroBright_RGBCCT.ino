// ElectroBright RGBCCT — installs the universal ElectroBright firmware
// (ESP32-C3 BLE light controller) and makes a new light a RGBCCT fixture: red,
// green, blue, cool white and warm white channels.
//
// Build: Arduino IDE, ESP32 Arduino core >= 3.0, board "ESP32C3 Dev Module",
// libraries "NimBLE-Arduino" 2.x and "ElectroBrightCore" (the shared core in
// firmware/core; install it once with firmware/tools/install_ide_core.sh).
// See firmware/README.md.
//
// Every fixture sketch builds the same firmware; the only difference is the
// type a light takes on its first install. A light that already has a type
// keeps it (the app changes it with SET_TYPE). The work runs in dedicated
// FreeRTOS tasks, so the Arduino loop task exits.

#include <Arduino.h>  // implicit in the Arduino build; explicit for IDE code analysis
#include <ElectroBrightCore.h>

static_assert(kCoreApi == 4, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

void setup() { App::start(FixtureType::Rgbcct); }

void loop() { vTaskDelete(nullptr); }
