// ElectroBright C3 firmware v3 — ESP32-C3 RGBW BLE light controller.
//
// Build: Arduino IDE, ESP32 Arduino core >= 3.0, board "ESP32C3 Dev Module",
// library "NimBLE-Arduino" 2.x. See README.md for details.
//
// All logic lives in src/: portable core (protocol, state, render, control)
// plus a thin ESP32 platform layer (src/platform). setup() only starts it;
// the work runs in dedicated FreeRTOS tasks, so the Arduino loop task exits.

#include <Arduino.h>  // implicit in the Arduino build; explicit for IDE code analysis

#include "src/platform/App.h"

void setup() { App::start(); }

void loop() { vTaskDelete(nullptr); }
