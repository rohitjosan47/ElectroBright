#pragma once
// ElectroBright shared firmware core — the one header a fixture sketch includes.
//
// The core holds everything the fixtures have in common (modes and effects,
// the BLE protocol, presets, sleep timer, sound). A fixture sketch in
// firmware/fixtures/<Name>/ only chooses the fixture type of a first install;
// every type is in the profile table (fixture/Profiles.h).

#include "platform/App.h"
