#pragma once
// ElectroBright firmware (ESP32-C3) — build-wide configuration.
//
// Every tunable lives here. This header is portable (no Arduino / ESP-IDF
// includes) so the host unit tests see exactly the same values as the device.

#include <stddef.h>
#include <stdint.h>

namespace cfg {

// --- Identity -------------------------------------------------------------------
// One universal image for every fixture type; a type's identity (model id,
// BLE name, layout, pins) lives in the profile table (fixture/Profiles.h).
constexpr const char* kFirmwareVersion = "3.8.0";

// Nordic UART Service
constexpr const char* kServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr const char* kRxCharUuid  = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";  // phone -> device (write / write-no-rsp)
constexpr const char* kTxCharUuid  = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";  // device -> phone (notify)

// --- LED PWM ----------------------------------------------------------------
// ~25 kHz: above hearing, so the fixtures' buck converters no longer whine
// under the pulsed load. The 80 MHz LEDC clock leaves 11 bits per period; the
// C3's LEDC adds 4 fractional duty bits (hardware dithering: the fraction adds
// one count in that many of every 16 periods), so duties are in 1/16 counts.
constexpr uint32_t kPwmFreqHz     = 25000;   // 80 MHz / 1.5625 / 2^11 (exact LEDC clock divider)
constexpr uint8_t  kPwmBits       = 11;      // counts per period (the most 80 MHz allows at ~25 kHz)
constexpr uint8_t  kPwmDitherBits = 4;       // LEDC fractional duty bits
constexpr uint16_t kPwmMaxDuty    = (1u << (kPwmBits + kPwmDitherBits)) - 1;   // 32767
// Smallest non-zero duty: one whole count in every period (no dithering below
// it), so the dimmest level is a steady pulse train, never a sparse one.
constexpr uint16_t kPwmMinDuty    = 1u << kPwmDitherBits;                    // 16
constexpr bool     kPwmPhaseStagger = true; // spread channel turn-on across the period

// --- Identify (IDENTIFY command) ---------------------------------------------
constexpr uint16_t kIdentifyOnMs   = 150;
constexpr uint16_t kIdentifyOffMs  = 150;
constexpr uint8_t  kIdentifyFlashes = 2;

// --- Probe (PROBE command) ------------------------------------------------------
// One physical output at a moderate fixed level (plain PWM duty, no gamma),
// whatever the active type, so the app can find out what is wired.
constexpr uint16_t kProbeDuty = kPwmMaxDuty / 4;
constexpr uint32_t kProbeMs   = 3000;   // then it switches itself off

// --- Fixture type (SET_TYPE) ---------------------------------------------------
constexpr uint32_t kRestartDelayMs = 300;  // after the OK has left, so the phone receives it

// --- Model -------------------------------------------------------------------
constexpr uint8_t kNumModes   = 13;
constexpr uint8_t kNumPresets = 15;
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
constexpr const char* kNvsNamespace = "eb3";           // settings, scene, presets (FACTORY_RESET erases it)
constexpr const char* kSystemNvsNamespace = "ebsys";  // the fixture type ("fx"); survives FACTORY_RESET
constexpr const char* kLegacyNvsNamespace = "eeprom";  // old firmware's EEPROM emulation (wiped once, no migration)

// --- Protocol / buffers -----------------------------------------------------------
constexpr size_t kMaxLineLength   = 96;    // longer text lines are discarded, never truncated-and-executed
constexpr size_t kMaxLinesPerBatch = 24;
constexpr size_t kRxStreamBytes   = 1024;
constexpr size_t kEgressBytes     = 1024;
constexpr uint16_t kPreferredMtu  = 517;   // the largest ATT MTU; the phone settles lower
constexpr size_t kOtaDataBufferBytes = 12288;  // > one update window (ota::kWindow) of DATA writes
constexpr size_t kOtaMaxWrite = 516;           // longest DATA write taken (MTU 517 - 3 + margin)

// --- Tasks ----------------------------------------------------------------------
constexpr uint32_t kControlStackBytes = 8192;  // esp_ota_end verifies the image on this task
constexpr uint32_t kRenderStackBytes  = 4096;
constexpr uint32_t kControlPriority   = 6;
constexpr uint32_t kRenderPriority    = 10;
constexpr uint32_t kControlWakeMs     = 50;     // max idle wait (timer precision, egress retry)
constexpr uint32_t kWatchdogTimeoutMs = 3000;

// --- Feedback -------------------------------------------------------------------
constexpr bool kConnectChirp = false;   // short beep when a phone connects
constexpr uint8_t kBuzzerDutyBits = 10;

}  // namespace cfg
