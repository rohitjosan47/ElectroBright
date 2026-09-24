#pragma once
// ElectroBright shared firmware core — the one header a fixture sketch includes.
//
// The core holds everything the fixtures have in common (modes and effects,
// the BLE protocol, presets, sleep timer, sound). A fixture sketch in
// firmware/fixtures/<Name>/ only adds its identity and wiring and starts it.

#include "platform/App.h"
