#pragma once
// ElectroBright W fixture (single white): identity, channel layout and wiring.
//
// Board: ESP32-C3 with one low-side MOSFET channel driving a single-colour
// white strip. It uses the W position of the RGBW board (the cool-white
// position of the RGBCCT / CCT boards), so any ElectroBright PCB becomes a
// single-white light by fitting one MOSFET; every other LED position is held
// low. See README.md in this folder and docs/wiring_guide.md.
//
// Rainbow (mode 10) is not available: it only changes colour at constant
// intensity, which a single white LED cannot show (CAPS MODES=1DFF).

#include <fixture/FixtureProfile.h>

static_assert(kCoreApi == 3, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

namespace fx {
namespace w {

// Identity (the app matches these; the cross-repo tests read them).
constexpr const char* kDeviceName = "ElectroBright_C3_W_V1";
constexpr const char* kModelId = "EB-C3-W-V1";
constexpr const char* kCapsReply = "CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,LAYOUT=W,MODES=1DFF";
constexpr const char* kNvsNamespace = "eb3w";  // separate from the other fixtures

// Wiring. GPIO 7 / 8 are never configured.
constexpr uint8_t kPinWhite = 5;
constexpr uint8_t kPinBuzzer = 6;
constexpr uint8_t kPinUnusedRed = 1;  // other LED positions of the board: not fitted, held low
constexpr uint8_t kPinUnusedGreen = 3;
constexpr uint8_t kPinUnusedBlue = 4;
constexpr uint8_t kPinUnusedWarm = 10;

inline constexpr FixtureProfile kProfile{
    &layouts::kW,
    kModelId,
    kDeviceName,
    kCapsReply,
    kNvsNamespace,
    {kPinWhite},
    kPinBuzzer,
    {kPinUnusedRed, kPinUnusedGreen, kPinUnusedBlue, kPinUnusedWarm},
    4,
    // Colour slots are r, g, b (always 0 here) and w. Power-up: full white;
    // police (manual): both sides full-brightness flashes.
    {{0, 0, 0, 255}, {0, 0, 0, 255}, {0, 0, 0, 255}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // unused: coloured effect light becomes brightness
    false,                     // no pre-3.x single-white firmware ever existed
};

}  // namespace w
}  // namespace fx
