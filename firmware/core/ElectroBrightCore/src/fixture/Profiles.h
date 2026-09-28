#pragma once
// The profile table: every fixture type one ElectroBright image can be, on the
// one board pin layout they share. The active type is stored in the light
// (fixture/FixtureSelect.h); a sketch in firmware/fixtures/ only chooses the
// type for a first install.

#include <string.h>

#include "FixtureProfile.h"

// ---- The board ----------------------------------------------------------------
// Every ElectroBright PCB has the same five low-side MOSFET positions and the
// buzzer; a fixture type fits the ones it uses. GPIO 7 / 8 (the old status LED)
// are never configured.
namespace board {
constexpr uint8_t kPinRed = 1;  // GPIO 1, not strapping GPIO 2
constexpr uint8_t kPinGreen = 3;
constexpr uint8_t kPinBlue = 4;
constexpr uint8_t kPinWhite = 5;  // W, or cool white on RGBCCT / CCT
constexpr uint8_t kPinWarm = 10;  // warm white: not a strapping, USB or UART pin
constexpr uint8_t kPinBuzzer = 6;

// Physical LED outputs in PROBE order: 0 red, 1 green, 2 blue, 3 white/cool, 4 warm.
constexpr uint8_t kNumOutputs = 5;
inline constexpr uint8_t kOutputPins[kNumOutputs] = {kPinRed, kPinGreen, kPinBlue, kPinWhite, kPinWarm};
}  // namespace board

namespace profiles {

// RGBW — the original light: red, green, blue and a white LED.
inline constexpr FixtureProfile kRgbw{
    FixtureType::Rgbw,
    &layouts::kRgbw,
    "EB-C3-RGBW-V1",
    "ElectroBright_C3_V1",
    {board::kPinRed, board::kPinGreen, board::kPinBlue, board::kPinWhite},
    board::kPinBuzzer,
    {board::kPinWarm},
    1,
    // Power-up white uses the RGB LEDs; police defaults match the app's (amber / white LED).
    {{255, 255, 255, 0}, {255, 165, 0, 0}, {0, 0, 0, 255}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // has a real W channel: no mixing
    true,
};

// RGB — the RGBW board without the white channel.
inline constexpr FixtureProfile kRgb{
    FixtureType::Rgb,
    &layouts::kRgb,
    "EB-C3-RGB-V1",
    "ElectroBright_C3_RGB_V1",
    {board::kPinRed, board::kPinGreen, board::kPinBlue},
    board::kPinBuzzer,
    {board::kPinWhite, board::kPinWarm},
    2,
    // White, amber and white: the RGBW light's police B is its white LED, here RGB white.
    {{255, 255, 255, 0}, {255, 165, 0, 0}, {255, 255, 255, 0}},
    // White-channel light from the effects (club white strobe, fireworks flash)
    // is rendered as equal-energy RGB white.
    {1.0f, 1.0f, 1.0f, 0.0f},
    false,  // no pre-3.x RGB firmware ever existed
};

// RGBCCT — RGB plus cool white (the W position) and warm white.
inline constexpr FixtureProfile kRgbcct{
    FixtureType::Rgbcct,
    &layouts::kRgbcct,
    "EB-C3-RGBCCT-V1",
    "ElectroBright_C3_RGBCCT_V1",
    {board::kPinRed, board::kPinGreen, board::kPinBlue, board::kPinWhite, board::kPinWarm},
    board::kPinBuzzer,
    {},
    0,
    // Colour slots are r, g, b, w (= cool white), ww (= warm white).
    // Power-up: both white LEDs (neutral white). Police: amber / both whites.
    {{0, 0, 0, 255, 255}, {255, 165, 0, 0, 0}, {0, 0, 0, 255, 255}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // has real white LEDs: no mixing
    false,                     // no pre-3.x RGBCCT firmware ever existed
};

// CCT — tunable white: cool white and warm white.
inline constexpr FixtureProfile kCct{
    FixtureType::Cct,
    &layouts::kCct,
    "EB-C3-CCT-V1",
    "ElectroBright_C3_CCT_V1",
    {board::kPinWhite, board::kPinWarm},
    board::kPinBuzzer,
    {board::kPinRed, board::kPinGreen, board::kPinBlue},
    3,
    // Colour slots are r, g, b (always 0 here), w (= cool white), ww (= warm white).
    // Power-up: both whites full. Police (manual colours): A warm, B cool.
    {{0, 0, 0, 255, 255}, {0, 0, 0, 0, 255}, {0, 0, 0, 255, 0}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // unused: coloured effect light becomes white temperature
    false,                     // no pre-3.x CCT firmware ever existed
};

// W — a single white channel on the W position. Rainbow (mode 10) only
// changes colour at constant intensity, which one white LED cannot show
// (CAPS MODES=1DFF).
inline constexpr FixtureProfile kW{
    FixtureType::W,
    &layouts::kW,
    "EB-C3-W-V1",
    "ElectroBright_C3_W_V1",
    {board::kPinWhite},
    board::kPinBuzzer,
    {board::kPinRed, board::kPinGreen, board::kPinBlue, board::kPinWarm},
    4,
    // Colour slots are r, g, b (always 0 here) and w. Power-up: full white;
    // police (manual): both sides full-brightness flashes.
    {{0, 0, 0, 255}, {0, 0, 0, 255}, {0, 0, 0, 255}},
    {0.0f, 0.0f, 0.0f, 0.0f},  // unused: coloured effect light becomes brightness
    false,                     // no pre-3.x single-white firmware ever existed
};

// Setup-needed mode: no type stored and none built in. Every LED output held
// low; only CAPS, VERSION, DIAG, PROBE, IDENTIFY and SET_TYPE are accepted.
inline constexpr FixtureProfile kNone{
    FixtureType::None,
    &layouts::kNone,
    "EB-C3-NONE-V1",
    "ElectroBright_C3_SETUP",
    {},
    board::kPinBuzzer,
    {board::kPinRed, board::kPinGreen, board::kPinBlue, board::kPinWhite, board::kPinWarm},
    5,
    {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}},
    {0.0f, 0.0f, 0.0f, 0.0f},
    false,
};

// Every selectable type, in CAPS TYPES= order.
inline constexpr const FixtureProfile* kAll[] = {&kRgbw, &kRgb, &kRgbcct, &kCct, &kW};

// The profile of a type; kNone for None or an unknown value.
inline const FixtureProfile& forType(FixtureType t) {
  for (const FixtureProfile* p : kAll) {
    if (p->type == t) return *p;
  }
  return kNone;
}

// The selectable type named `name` (its layout name, e.g. "RGBCCT"; exact
// length `len`, case-insensitive); nullptr when there is none.
inline const FixtureProfile* forName(const char* name, size_t len) {
  for (const FixtureProfile* p : kAll) {
    const char* n = p->layout->name;
    if (strlen(n) != len) continue;
    size_t i = 0;
    for (; i < len; ++i) {
      const char c = (name[i] >= 'a' && name[i] <= 'z') ? static_cast<char>(name[i] - 'a' + 'A') : name[i];
      if (c != n[i]) break;
    }
    if (i == len) return p;
  }
  return nullptr;
}

}  // namespace profiles
