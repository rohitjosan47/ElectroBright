#pragma once
// ElectroBright firmware (ESP32-C3) — build-wide configuration.
//
// Every tunable lives here. This header is portable (no Arduino / ESP-IDF
// includes) so the host unit tests see exactly the same values as the device.

#include <stddef.h>
#include <stdint.h>

namespace cfg {

// --- Identity (must match the Flutter app's device catalog) -----------------
constexpr const char* kDeviceName   = "ElectroBright_C3_V1";   // app scans for the "ElectroBright_C3_" prefix
constexpr const char* kModelId      = "EB-C3-RGBW-V1";         // exact INFO reply value the app resolves
constexpr const char* kFirmwareVersion = "3.4.0";
constexpr const char* kCapsReply    = "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL";

// Nordic UART Service
constexpr const char* kServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr const char* kRxCharUuid  = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";  // phone -> device (write / write-no-rsp)
constexpr const char* kTxCharUuid  = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";  // device -> phone (notify)

// --- Pins (ESP32-C3) -------------------------------------------------------
// GPIO 7 / 8 (old status LED) are intentionally never configured.
constexpr uint8_t kPinRed    = 1;   // GPIO 1, not strapping GPIO 2
constexpr uint8_t kPinGreen  = 3;
constexpr uint8_t kPinBlue   = 4;
constexpr uint8_t kPinWhite  = 5;
constexpr uint8_t kPinBuzzer = 6;

// --- LED PWM ----------------------------------------------------------------
constexpr uint32_t kPwmFreqHz   = 4882;    // 80 MHz / 2^14
constexpr uint8_t  kPwmBits     = 14;
constexpr uint16_t kPwmMaxDuty  = (1u << kPwmBits) - 1;   // 16383
constexpr bool     kPwmPhaseStagger = true; // spread channel turn-on across the period

// --- Model -------------------------------------------------------------------
constexpr uint8_t kNumModes   = 13;
constexpr uint8_t kNumPresets = 25;
constexpr uint8_t kMinLevel   = 1;   // speed / frequency slider range
constexpr uint8_t kMaxLevel   = 10;
constexpr uint32_t kTimerMaxSeconds = 86400;   // 24 h

// --- Render -------------------------------------------------------------------
constexpr uint32_t kRenderPeriodUs   = 5000;   // 200 Hz fixed frame rate
constexpr float    kColorTauMs       = 45.0f;  // base colour smoothing time constant
constexpr float    kBrightnessTauMs  = 70.0f;  // master brightness smoothing time constant
constexpr float    kModeCrossfadeMs  = 300.0f;
constexpr uint16_t kSleepFadeMs      = 400;    // SLEEP / WAKE
constexpr uint16_t kTimerSleepFadeMs = 2000;   // auto-sleep timer expiry
constexpr uint16_t kBootFadeMs       = 600;    // fade-in from black after power-up

// --- Persistence -------------------------------------------------------------
constexpr uint32_t kPersistDebounceMs   = 3000;   // commit this long after the last change...
constexpr uint32_t kPersistMaxLatencyMs = 15000;  // ...but never later than this after the first change
constexpr const char* kNvsNamespace       = "eb3";
constexpr const char* kLegacyNvsNamespace = "eeprom";  // old firmware's EEPROM emulation (wiped once, no migration)

// --- Protocol / buffers -----------------------------------------------------------
constexpr size_t kMaxLineLength   = 96;    // longer text lines are discarded, never truncated-and-executed
constexpr size_t kMaxLinesPerBatch = 24;
constexpr size_t kRxStreamBytes   = 1024;
constexpr size_t kEgressBytes     = 1024;
constexpr uint16_t kPreferredMtu  = 247;

// --- Tasks ----------------------------------------------------------------------
constexpr uint32_t kControlStackBytes = 6144;
constexpr uint32_t kRenderStackBytes  = 4096;
constexpr uint32_t kControlPriority   = 6;
constexpr uint32_t kRenderPriority    = 10;
constexpr uint32_t kControlWakeMs     = 50;     // max idle wait (timer precision, egress retry)
constexpr uint32_t kWatchdogTimeoutMs = 3000;

// --- Feedback -------------------------------------------------------------------
constexpr bool kConnectChirp = false;   // short beep when a phone connects
constexpr uint8_t kBuzzerDutyBits = 10;

}  // namespace cfg
