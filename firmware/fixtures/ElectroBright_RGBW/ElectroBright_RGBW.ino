// ElectroBright RGBW fixture — ESP32-C3 BLE light controller with red, green,
// blue and white channels.
//
// Build: Arduino IDE, ESP32 Arduino core >= 3.0, board "ESP32C3 Dev Module",
// libraries "NimBLE-Arduino" 2.x and "ElectroBrightCore" (the shared core in
// firmware/core; install it once with firmware/tools/install_ide_core.sh).
// See firmware/README.md.
//
// Fixture.h holds this fixture's identity, channel layout and pins. setup()
// only starts the core with it; the work runs in dedicated FreeRTOS tasks, so
// the Arduino loop task exits.

#include <Arduino.h>  // implicit in the Arduino build; explicit for IDE code analysis
#include <ElectroBrightCore.h>

#include "Fixture.h"

void setup() { App::start(fx::rgbw::kProfile); }

void loop() { vTaskDelete(nullptr); }
