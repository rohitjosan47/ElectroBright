#pragma once
// ElectroBright RGBW fixture: identity, channel layout and wiring.
//
// Board: ESP32-C3, four low-side MOSFET channels (see docs/wiring_guide.md).

#include <fixture/FixtureProfile.h>

static_assert(kCoreApi == 3, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

namespace fx {
namespace rgbw {

// Identity (the app matches these; the cross-repo tests read them).
constexpr const char* kDeviceName = "ElectroBright_C3_V1";
constexpr const char* kModelId = "EB-C3-RGBW-V1";
constexpr const char* kCapsReply = "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,LAYOUT=RGBW";
constexpr const char* kNvsNamespace = "eb3";

// Wiring (GPIO 7 / 8 — the old status LED — are never configured).
constexpr uint8_t kPinRed = 1;  // GPIO 1, not strapping GPIO 2
constexpr uint8_t kPinGreen = 3;
constexpr uint8_t kPinBlue = 4;
constexpr uint8_t kPinWhite = 5;
constexpr uint8_t kPinBuzzer = 6;

inline constexpr FixtureProfile kProfile{
    &layouts::kRgbw,
    kModelId,
    kDeviceName,
    kCapsReply,
    kNvsNamespace,
    {kPinRed, kPinGreen, kPinBlue, kPinWhite},
    kPinBuzzer,
    {0, 0},
    0,
    // Power-up white uses the RGB LEDs; police defaults match the app's (amber / white LED).
    {{255, 255, 255, 0}, {255, 165, 0, 0}, {0, 0, 0, 255}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // has a real W channel: no mixing
    true,
};

}  // namespace rgbw
}  // namespace fx
