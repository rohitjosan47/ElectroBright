#pragma once

#include <Arduino.h>

// --- PIN CONFIGURATION (ESP32-C3) ---
const uint8_t PIN_RED = 2;
const uint8_t PIN_GREEN = 3;
const uint8_t PIN_BLUE = 4;
const uint8_t PIN_WHITE = 5;
const uint8_t PIN_BUZZER = 6;
const uint8_t PIN_STATUS_GREEN = 7; 
const uint8_t PIN_STATUS_RED = 8; 

enum StatusColorEvent {
  STATUS_EVENT_NONE = 0,
  STATUS_EVENT_ADVERTISING_BREATHE = 1,
  STATUS_EVENT_CONNECT_BLINK = 2,
  STATUS_EVENT_MODE_CHANGE = 3
};

// --- BLE CONFIGURATION (Nordic UART Service) ---
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// --- CONSTANTS ---
const uint8_t MAX_SPEED = 10;
const uint8_t NUM_MODES = 13;
const uint8_t NUM_PRESETS = 25;
const uint16_t EEPROM_MAGIC_BYTE_V5 = 0xEB05;
const uint16_t EEPROM_MAGIC_BYTE_V6 = 0xEB06;
const uint16_t EEPROM_MAGIC_BYTE_V7 = 0xEB07;
const uint16_t EEPROM_MAGIC_BYTE_V8 = 0xEB08;
const uint16_t EEPROM_MAGIC_BYTE_V9 = 0xEB09;
const uint16_t EEPROM_MAGIC_BYTE = 0xEB0A;
const uint8_t BUFFER_SIZE = 64;
// NOTE: Every additional call site that force-commits (markColorDirty(true),
// markModeSettingsDirty(true)) bypasses the 5s coalescing window by design.
// Do not use force-commits in high-frequency loops or wear-leveling will be defeated.
const uint32_t EEPROM_COMMIT_DELAY = 5000;

// --- STRUCTS ---
struct __attribute__((packed)) SystemState {
  uint8_t red;
  uint8_t green;
  uint8_t blue;
  uint8_t white;
  uint8_t brightness;
  uint8_t mode;
  uint8_t modeSpeed[NUM_MODES];
  uint8_t modeFrequency[NUM_MODES];
  uint8_t fireworkColorMode; // 0 = MANUAL, 1 = AUTO
  uint8_t clubColorMode;     // 0 = MANUAL, 1 = AUTO
  uint8_t policeColorMode;   // 0 = MANUAL, 1 = AUTO
  uint8_t policeColorAR, policeColorAG, policeColorAB, policeColorAW;
  uint8_t policeColorBR, policeColorBG, policeColorBB, policeColorBW;
  uint16_t magic;
  uint8_t crc;
};

struct SystemStateV5 {
  uint8_t red, green, blue, white, brightness, mode, speed, effectParam;
  uint16_t magic;
  uint8_t crc;
};

struct SystemStateV6 {
  uint8_t red, green, blue, white, brightness, mode;
  uint8_t modeSpeed[12];
  uint8_t modeFrequency[12];
  uint16_t magic;
  uint8_t crc;
};

struct SystemStateV7 {
  uint8_t red, green, blue, white, brightness, mode;
  uint8_t modeSpeed[12];
  uint8_t modeFrequency[12];
  uint8_t fireworkColorMode;
  uint16_t magic;
  uint8_t crc;
};

struct SystemStateV8 {
  uint8_t red, green, blue, white, brightness, mode;
  uint8_t modeSpeed[12];
  uint8_t modeFrequency[12];
  uint8_t fireworkColorMode;
  uint8_t clubColorMode;
  uint16_t magic;
  uint8_t crc;
};

struct SystemStateV9 {
  uint8_t red, green, blue, white, brightness, mode;
  uint8_t modeSpeed[13];
  uint8_t modeFrequency[13];
  uint8_t fireworkColorMode;
  uint8_t clubColorMode;
  uint16_t magic;
  uint8_t crc;
};

// --- SHARED GLOBALS (DEFINED IN MAIN .INO) ---
extern SystemState currentState;
extern SystemState eepromBuffer;

extern bool colorDirty;
extern bool modeSettingsDirty;
extern uint32_t colorDirtyMillis;
extern uint32_t modeSettingsDirtyMillis;

extern uint32_t currentMillis;
extern uint32_t previousStatusMillis;

extern bool sleepMode;
extern bool timerActive;
extern uint32_t timerStartMillis;
extern uint32_t timerDurationMs;

extern bool soundEnabled;

extern bool deviceConnected;
extern bool oldDeviceConnected;

extern StatusColorEvent currentStatusEvent;
extern uint32_t statusEventStart;

// --- CROSS-MODULE FUNCTION DECLARATIONS ---
void playSoundEvent(uint8_t eventId);
void resetEffectState();
void applyLEDs(uint8_t r, uint8_t g, uint8_t b, uint8_t w);
void bleSendString(const char *str);
void bleSendString(const String &str);
