#pragma once
// ElectroBright RGB fixture: identity, channel layout and wiring.
//
// Board: the RGBW board without the white channel — ESP32-C3 with three
// low-side MOSFET channels (R, G, B). The W position (GPIO 5 and its MOSFET)
// is left unpopulated; GPIO 5 is still driven low so a fitted gate can never
// float on. See README.md in this folder and docs/wiring_guide.md.

#include <fixture/FixtureProfile.h>

static_assert(kCoreApi == 2, "ElectroBrightCore does not match this sketch: run firmware/tools/install_ide_core.sh");

namespace fx {
namespace rgb {

// Identity (the app matches these; the cross-repo tests read them).
constexpr const char* kDeviceName = "ElectroBright_C3_RGB_V1";
constexpr const char* kModelId = "EB-C3-RGB-V1";
constexpr const char* kCapsReply = "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,LAYOUT=RGB";
constexpr const char* kNvsNamespace = "eb3rgb";  // separate from the RGBW light's "eb3"

// Wiring (same board as RGBW; GPIO 7 / 8 are never configured).
constexpr uint8_t kPinRed = 1;  // GPIO 1, not strapping GPIO 2
constexpr uint8_t kPinGreen = 3;
constexpr uint8_t kPinBlue = 4;
constexpr uint8_t kPinUnusedWhite = 5;  // unpopulated W channel: held low
constexpr uint8_t kPinBuzzer = 6;

inline constexpr FixtureProfile kProfile{
    &layouts::kRgb,
    kModelId,
    kDeviceName,
    kCapsReply,
    kNvsNamespace,
    {kPinRed, kPinGreen, kPinBlue},
    kPinBuzzer,
    {kPinUnusedWhite, 0},
    1,
    // White, amber and white: the RGBW light's police B is its white LED, here RGB white.
    {{255, 255, 255, 0}, {255, 165, 0, 0}, {255, 255, 255, 0}},
    // White-channel light from the effects (club white strobe, fireworks flash)
    // is rendered as equal-energy RGB white.
    {1.0f, 1.0f, 1.0f, 0.0f},
    false,  // no pre-3.x RGB firmware ever existed
};

}  // namespace rgb
}  // namespace fx
