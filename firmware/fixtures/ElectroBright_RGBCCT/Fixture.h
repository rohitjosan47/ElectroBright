#pragma once
// ElectroBright RGBCCT fixture: identity, channel layout and wiring.
//
// Board: the RGBW board plus one channel — ESP32-C3 with five low-side MOSFET
// channels: red, green, blue for colours, cool white and warm white for whites
// (an RGB+CCT "RGBWW" strip). See README.md in this folder and
// docs/wiring_guide.md.

#include <fixture/FixtureProfile.h>

static_assert(kCoreApi == 3, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

namespace fx {
namespace rgbcct {

// Identity (the app matches these; the cross-repo tests read them).
constexpr const char* kDeviceName = "ElectroBright_C3_RGBCCT_V1";
constexpr const char* kModelId = "EB-C3-RGBCCT-V1";
constexpr const char* kCapsReply = "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,LAYOUT=RGBCCT";
constexpr const char* kNvsNamespace = "eb3rgbcct";  // separate from the other fixtures

// Wiring (RGBW board positions; W becomes cool white, warm white is added on
// GPIO 10: not a strapping pin, not USB/UART). GPIO 7 / 8 are never configured.
constexpr uint8_t kPinRed = 1;  // GPIO 1, not strapping GPIO 2
constexpr uint8_t kPinGreen = 3;
constexpr uint8_t kPinBlue = 4;
constexpr uint8_t kPinCoolWhite = 5;
constexpr uint8_t kPinWarmWhite = 10;
constexpr uint8_t kPinBuzzer = 6;

inline constexpr FixtureProfile kProfile{
    &layouts::kRgbcct,
    kModelId,
    kDeviceName,
    kCapsReply,
    kNvsNamespace,
    {kPinRed, kPinGreen, kPinBlue, kPinCoolWhite, kPinWarmWhite},
    kPinBuzzer,
    {0, 0},
    0,
    // Colour slots are r, g, b, w (= cool white), ww (= warm white).
    // Power-up: both white LEDs (neutral white). Police: amber / both whites.
    {{0, 0, 0, 255, 255}, {255, 165, 0, 0, 0}, {0, 0, 0, 255, 255}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // has real white LEDs: no mixing
    false,                     // no pre-3.x RGBCCT firmware ever existed
};

}  // namespace rgbcct
}  // namespace fx
