// ElectroBright update image — the universal ElectroBright firmware without a
// default fixture type, for wireless updates (tools/build_update_image.sh).
//
// A light that has a type keeps it. A light without one starts in
// setup-needed mode (all LED outputs off) until the app sends SET_TYPE; this
// image never invents a type. Build it with tools/build_update_image.sh, not
// for a first install over USB (use a sketch in firmware/fixtures/ for that).

#include <Arduino.h>  // implicit in the Arduino build; explicit for IDE code analysis
#include <ElectroBrightCore.h>

static_assert(kCoreApi == 4, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

void setup() { App::start(); }

void loop() { vTaskDelete(nullptr); }
