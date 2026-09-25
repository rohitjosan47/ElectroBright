#pragma once
// ElectroBright CCT fixture: identity, channel layout and wiring.
//
// Board: ESP32-C3 with two low-side MOSFET channels, cool white and warm white
// (a tunable-white / CCT strip). It uses the white positions of the RGBCCT
// board, so a 5-channel PCB becomes a CCT light by fitting only those two
// MOSFETs; the unused colour positions (GPIO 1, 3, 4) are held low. See
// README.md in this folder and docs/wiring_guide.md.

#include <fixture/FixtureProfile.h>

static_assert(kCoreApi == 3, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

namespace fx {
namespace cct {

// Identity (the app matches these; the cross-repo tests read them).
constexpr const char* kDeviceName = "ElectroBright_C3_CCT_V1";
constexpr const char* kModelId = "EB-C3-CCT-V1";
constexpr const char* kCapsReply = "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,LAYOUT=CCT";
constexpr const char* kNvsNamespace = "eb3cct";  // separate from the other fixtures

// Wiring. GPIO 7 / 8 are never configured.
constexpr uint8_t kPinCoolWhite = 5;
constexpr uint8_t kPinWarmWhite = 10;  // not a strapping, USB or UART pin
constexpr uint8_t kPinBuzzer = 6;
constexpr uint8_t kPinUnusedRed = 1;  // colour positions of the board: not fitted, held low
constexpr uint8_t kPinUnusedGreen = 3;
constexpr uint8_t kPinUnusedBlue = 4;

inline constexpr FixtureProfile kProfile{
    &layouts::kCct,
    kModelId,
    kDeviceName,
    kCapsReply,
    kNvsNamespace,
    {kPinCoolWhite, kPinWarmWhite},
    kPinBuzzer,
    {kPinUnusedRed, kPinUnusedGreen, kPinUnusedBlue},
    3,
    // Colour slots are r, g, b (always 0 here), w (= cool white), ww (= warm white).
    // Power-up: both whites full. Police (manual colours): A warm, B cool.
    {{0, 0, 0, 255, 255}, {0, 0, 0, 0, 255}, {0, 0, 0, 255, 0}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // unused: coloured effect light becomes white temperature
    false,                     // no pre-3.x CCT firmware ever existed
};

}  // namespace cct
}  // namespace fx
