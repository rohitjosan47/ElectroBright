// ElectroBright_ESP32C3_BLE.ino
/*
 * Electrobright v6.0 - ESP32-C3 BLE PORT
 * Fully compatible with iOS and Android via BLE UART (NUS)
 */
#include <EEPROM.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

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

StatusColorEvent currentStatusEvent = STATUS_EVENT_ADVERTISING_BREATHE;
uint32_t statusEventStart = 0;

// --- BLE CONFIGURATION (Nordic UART Service) ---
BLEServer *pServer = NULL;
BLECharacteristic * pTxCharacteristic;
bool deviceConnected = false;
bool oldDeviceConnected = false;

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

// --- STATE VARIABLES ---
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

SystemState currentState;
SystemState eepromBuffer;

bool colorDirty = false;
bool modeSettingsDirty = false;
uint32_t colorDirtyMillis = 0;
uint32_t modeSettingsDirtyMillis = 0;

uint32_t currentMillis = 0;
uint32_t previousStatusMillis = 0;

bool sleepMode = false;
bool timerActive = false;
uint32_t timerStartMillis = 0;
uint32_t timerDurationMs = 0;

char cmdBuffer[BUFFER_SIZE];
#define CMD_QUEUE_LEN 6
char cmdQueue[CMD_QUEUE_LEN][BUFFER_SIZE];
volatile uint8_t cmdQueueHead = 0, cmdQueueTail = 0, cmdQueueCount = 0;
portMUX_TYPE cmdMux = portMUX_INITIALIZER_UNLOCKED;
uint8_t cmdIndex = 0;
bool cmdOverflowed = false;

uint32_t effectStep = 0;

uint16_t currentBaseR = 0;
uint16_t currentBaseG = 0;
uint16_t currentBaseB = 0;
uint16_t currentBaseW = 0;
uint8_t baseR = 0;
uint8_t baseG = 0;
uint8_t baseB = 0;
uint8_t baseW = 0;

uint16_t tvCurrentInt = 114 << 8;
uint16_t tvTargetInt = 114 << 8;
uint16_t tvCurrentShift = 255 << 8;
uint16_t tvTargetShift = 255 << 8;
uint32_t tvLastSceneChangeTime = 0;
uint32_t tvNextSceneInterval = 0;
uint32_t tvLastFrameMillis = 0;

uint8_t thunderState = 0;
uint32_t thunderStateTimer = 0;
uint32_t thunderStateDuration = 0;
uint16_t thunderFlashIntensity = 0;
bool thunderHasSecondary = false;

uint8_t fwState = 0;
uint32_t fwStateTimer = 0;
uint32_t fwStateDuration = 0;
uint8_t fwR = 0, fwG = 0, fwB = 0;
uint8_t fwCrackleCeiling = 0;
uint8_t fwCrackleBright = 0;
uint8_t fwLastHueBucket = 255;

uint8_t fbState = 0;
uint8_t fbFaultType = 0;
uint8_t fbFaultStep = 0;
uint32_t fbStateTimer = 0;
uint32_t fbStateDuration = 0;
uint8_t fbFaultLevel = 255;

uint8_t clState = 0;
uint8_t clPatternType = 0;
uint8_t clPatternStep = 0;
uint32_t clStateTimer = 0;
uint32_t clStateDuration = 0;
uint8_t clR = 0, clG = 0, clB = 0, clW = 0;
uint8_t clLastHueBucket = 255;

uint16_t cdLayerSlow = 200 << 4;
uint16_t cdLayerMid  = 200 << 4;
uint16_t cdLayerFast = 200 << 4;
uint16_t cdTargetSlow = 200 << 4;
uint16_t cdTargetMid  = 200 << 4;
uint16_t cdTargetFast = 200 << 4;
uint32_t cdLastUpdateMillis = 0;
uint32_t cdSlowRetargetMillis = 0;
uint32_t cdMidRetargetMillis = 0;
uint32_t cdFastRetargetMillis = 0;
uint8_t  cdDipActive = 0;
uint32_t cdDipTimer = 0;
uint32_t cdDipDuration = 0;
uint32_t cdDipCooldownEnd = 0;

uint16_t fireLayerMajor = 200 << 4;
uint16_t fireLayerMinor = 200 << 4;
uint16_t fireTargetMajor = 200 << 4;
uint16_t fireTargetMinor = 200 << 4;
uint32_t fireMajorRetargetMillis = 0;
uint32_t fireMinorRetargetMillis = 0;
uint32_t fireLastUpdateMillis = 0;
uint8_t  fireFlareActive = 0;
uint32_t fireFlareTimer = 0;
uint32_t fireFlareDuration = 0;
uint32_t fireFlareRise = 0;
uint32_t fireFlareCooldownEnd = 0;

uint8_t  polState = 0;
uint8_t  polFlashCount = 0;
bool     polFlashOn = false;
uint32_t polLastUpdate = 0;

bool soundEnabled = true;

uint8_t buzzerEvent = 0;
uint8_t buzzerStep = 0;
uint32_t buzzerStepStart = 0;
uint32_t buzzerMicros = 0;
bool buzzerPinState = false;

// CRC8
uint8_t calculateCRC8(const SystemState &state) {
  uint8_t crc = 0;
  const uint8_t *data = (const uint8_t *)&state;
  for (uint8_t i = 0; i < sizeof(SystemState) - 1; i++) {
    crc ^= data[i];
    for (uint8_t j = 0; j < 8; j++)
      crc = (crc & 0x80) ? (crc << 1) ^ 0x07 : (crc << 1);
  }
  return crc;
}

void parseCommand(char *cmd);

void bleSendString(const char *str) {
  if (deviceConnected && pTxCharacteristic) {
    size_t len = strlen(str);
    if (len == 0) return;
    if (len + 1 < 512) {
      char outBuf[512];
      memcpy(outBuf, str, len);
      outBuf[len] = '\n';
      pTxCharacteristic->setValue((uint8_t*)outBuf, len + 1);
      pTxCharacteristic->notify();
    } else {
      char *dyn = (char*)malloc(len + 2);
      if (dyn) {
        memcpy(dyn, str, len);
        dyn[len] = '\n';
        pTxCharacteristic->setValue((uint8_t*)dyn, len + 1);
        pTxCharacteristic->notify();
        free(dyn);
      }
    }
  }
}

void bleSendString(const String &str) {
  bleSendString(str.c_str());
}

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
    }
};

class MyCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      String rxValue = pCharacteristic->getValue();
      if (rxValue.length() > 0) {
        for (int i = 0; i < rxValue.length(); i++) {
            char c = rxValue[i];
            if (c == '\n' || c == '\r') {
              if (cmdOverflowed) {
                cmdOverflowed = false;
                cmdIndex = 0;
              } else if (cmdIndex > 0) {
                cmdBuffer[cmdIndex] = '\0';
                portENTER_CRITICAL(&cmdMux);
                if (cmdQueueCount < CMD_QUEUE_LEN) {
                  strlcpy(cmdQueue[cmdQueueTail], cmdBuffer, BUFFER_SIZE);
                  cmdQueueTail = (cmdQueueTail + 1) % CMD_QUEUE_LEN;
                  cmdQueueCount++;
                }
                portEXIT_CRITICAL(&cmdMux);
                cmdIndex = 0;
              }
            } else {
              if (!cmdOverflowed) {
                if (cmdIndex < BUFFER_SIZE - 1) {
                  cmdBuffer[cmdIndex++] = c;
                } else {
                  cmdOverflowed = true;
                }
              }
            }
        }
      }
    }
};

void updateEEPROM(bool force = false);

void markColorDirty(bool forceCommit = false) {
  colorDirty = true; colorDirtyMillis = currentMillis;
  if (forceCommit) updateEEPROM(true);
}
void markModeSettingsDirty(bool forceCommit = false) {
  modeSettingsDirty = true; modeSettingsDirtyMillis = currentMillis;
  if (forceCommit) updateEEPROM(true);
}

void setDefaultState() {
  currentState.red = 255; currentState.green = 255; currentState.blue = 255; currentState.white = 0;
  currentState.brightness = 255; currentState.mode = 1;
  for (int i=0; i<NUM_MODES; i++) { currentState.modeSpeed[i] = 5; currentState.modeFrequency[i] = 5; }
  currentState.fireworkColorMode = 0;
  currentState.clubColorMode = 0;
  currentState.policeColorMode = 1;
  currentState.policeColorAR = 255; currentState.policeColorAG = 165; currentState.policeColorAB = 0; currentState.policeColorAW = 0;
  currentState.policeColorBR = 0; currentState.policeColorBG = 0; currentState.policeColorBB = 0; currentState.policeColorBW = 255;
  currentState.magic = EEPROM_MAGIC_BYTE;
  currentState.crc = calculateCRC8(currentState);
  markColorDirty(true); markModeSettingsDirty(true);
}

void loadStateFromEEPROM() {
  SystemStateV5 oldState;
  EEPROM.get(0, oldState);
  if (oldState.magic == EEPROM_MAGIC_BYTE_V5) {
    currentState.red = oldState.red; currentState.green = oldState.green;
    currentState.blue = oldState.blue; currentState.white = oldState.white;
    currentState.brightness = oldState.brightness; currentState.mode = oldState.mode;
    for (int i=0; i<12; i++) { currentState.modeSpeed[i] = oldState.speed; currentState.modeFrequency[i] = 5; }
    currentState.modeSpeed[12] = 5; currentState.modeFrequency[12] = 5;
    currentState.fireworkColorMode = 0;
    currentState.clubColorMode = 0;
    currentState.policeColorMode = 1;
    currentState.policeColorAR = 255; currentState.policeColorAG = 165; currentState.policeColorAB = 0; currentState.policeColorAW = 0;
    currentState.policeColorBR = 0; currentState.policeColorBG = 0; currentState.policeColorBB = 0; currentState.policeColorBW = 255;
    currentState.magic = EEPROM_MAGIC_BYTE;
    currentState.crc = calculateCRC8(currentState);
    markColorDirty(true); markModeSettingsDirty(true);
    return;
  }

  SystemStateV6 v6State;
  EEPROM.get(0, v6State);
  if (v6State.magic == EEPROM_MAGIC_BYTE_V6) {
    currentState.red = v6State.red; currentState.green = v6State.green;
    currentState.blue = v6State.blue; currentState.white = v6State.white;
    currentState.brightness = v6State.brightness; currentState.mode = v6State.mode;
    for (int i=0; i<12; i++) {
      currentState.modeSpeed[i] = v6State.modeSpeed[i];
      currentState.modeFrequency[i] = v6State.modeFrequency[i];
    }
    currentState.modeSpeed[12] = 5; currentState.modeFrequency[12] = 5;
    currentState.fireworkColorMode = 0;
    currentState.clubColorMode = 0;
    currentState.policeColorMode = 1;
    currentState.policeColorAR = 255; currentState.policeColorAG = 165; currentState.policeColorAB = 0; currentState.policeColorAW = 0;
    currentState.policeColorBR = 0; currentState.policeColorBG = 0; currentState.policeColorBB = 0; currentState.policeColorBW = 255;
    currentState.magic = EEPROM_MAGIC_BYTE;
    currentState.crc = calculateCRC8(currentState);
    markColorDirty(true); markModeSettingsDirty(true);
    return;
  }
  
  SystemStateV7 v7State;
  EEPROM.get(0, v7State);
  if (v7State.magic == EEPROM_MAGIC_BYTE_V7) {
    currentState.red = v7State.red; currentState.green = v7State.green;
    currentState.blue = v7State.blue; currentState.white = v7State.white;
    currentState.brightness = v7State.brightness; currentState.mode = v7State.mode;
    for (int i=0; i<12; i++) {
      currentState.modeSpeed[i] = v7State.modeSpeed[i];
      currentState.modeFrequency[i] = v7State.modeFrequency[i];
    }
    currentState.modeSpeed[12] = 5; currentState.modeFrequency[12] = 5;
    currentState.fireworkColorMode = v7State.fireworkColorMode;
    currentState.clubColorMode = 0;
    currentState.policeColorMode = 1;
    currentState.policeColorAR = 255; currentState.policeColorAG = 165; currentState.policeColorAB = 0; currentState.policeColorAW = 0;
    currentState.policeColorBR = 0; currentState.policeColorBG = 0; currentState.policeColorBB = 0; currentState.policeColorBW = 255;
    currentState.magic = EEPROM_MAGIC_BYTE;
    currentState.crc = calculateCRC8(currentState);
    markColorDirty(true); markModeSettingsDirty(true);
    return;
  }

  SystemStateV8 v8State;
  EEPROM.get(0, v8State);
  if (v8State.magic == EEPROM_MAGIC_BYTE_V8) {
    currentState.red = v8State.red; currentState.green = v8State.green;
    currentState.blue = v8State.blue; currentState.white = v8State.white;
    currentState.brightness = v8State.brightness; currentState.mode = v8State.mode;
    for (int i=0; i<12; i++) {
      currentState.modeSpeed[i] = v8State.modeSpeed[i];
      currentState.modeFrequency[i] = v8State.modeFrequency[i];
    }
    currentState.modeSpeed[12] = 5; currentState.modeFrequency[12] = 5;
    currentState.fireworkColorMode = v8State.fireworkColorMode;
    currentState.clubColorMode = v8State.clubColorMode;
    currentState.policeColorMode = 1;
    currentState.policeColorAR = 255; currentState.policeColorAG = 165; currentState.policeColorAB = 0; currentState.policeColorAW = 0;
    currentState.policeColorBR = 0; currentState.policeColorBG = 0; currentState.policeColorBB = 0; currentState.policeColorBW = 255;
    currentState.magic = EEPROM_MAGIC_BYTE;
    currentState.crc = calculateCRC8(currentState);
    markColorDirty(true); markModeSettingsDirty(true);
    return;
  }

  SystemStateV9 v9State;
  EEPROM.get(0, v9State);
  if (v9State.magic == EEPROM_MAGIC_BYTE_V9) {
    currentState.red = v9State.red; currentState.green = v9State.green;
    currentState.blue = v9State.blue; currentState.white = v9State.white;
    currentState.brightness = v9State.brightness; currentState.mode = v9State.mode;
    for (int i=0; i<13; i++) {
      currentState.modeSpeed[i] = v9State.modeSpeed[i];
      currentState.modeFrequency[i] = v9State.modeFrequency[i];
    }
    currentState.fireworkColorMode = v9State.fireworkColorMode;
    currentState.clubColorMode = v9State.clubColorMode;
    currentState.policeColorMode = 1;
    currentState.policeColorAR = 255; currentState.policeColorAG = 165; currentState.policeColorAB = 0; currentState.policeColorAW = 0;
    currentState.policeColorBR = 0; currentState.policeColorBG = 0; currentState.policeColorBB = 0; currentState.policeColorBW = 255;
    currentState.magic = EEPROM_MAGIC_BYTE;
    currentState.crc = calculateCRC8(currentState);
    markColorDirty(true); markModeSettingsDirty(true);
    return;
  }

  EEPROM.get(0, eepromBuffer);
  if (eepromBuffer.magic == EEPROM_MAGIC_BYTE &&
      calculateCRC8(eepromBuffer) == eepromBuffer.crc &&
      eepromBuffer.mode > 0 && eepromBuffer.mode <= NUM_MODES) {
    currentState = eepromBuffer;
  } else {
    setDefaultState();
  }
}

void updateEEPROM(bool force) {
  bool needsCommit = false;
  if (force || (colorDirty && currentMillis - colorDirtyMillis >= EEPROM_COMMIT_DELAY)) {
    colorDirty = false; needsCommit = true;
  }
  if (force || (modeSettingsDirty && currentMillis - modeSettingsDirtyMillis >= EEPROM_COMMIT_DELAY)) {
    modeSettingsDirty = false; needsCommit = true;
  }
  if (!needsCommit && !force) return;
  
  currentState.crc = calculateCRC8(currentState);
  if (memcmp(&currentState, &eepromBuffer, sizeof(SystemState)) != 0) {
    EEPROM.put(0, currentState);
    EEPROM.commit();
    eepromBuffer = currentState;
  }
}

void applyLEDs(uint8_t r, uint8_t g, uint8_t b, uint8_t w) {
  if (sleepMode) {
    analogWrite(PIN_RED, 0); analogWrite(PIN_GREEN, 0); analogWrite(PIN_BLUE, 0); analogWrite(PIN_WHITE, 0);
    return;
  }
  uint32_t br = currentState.brightness;
  analogWrite(PIN_RED, (uint32_t(r) * br * 4095) / 65025);
  analogWrite(PIN_GREEN, (uint32_t(g) * br * 4095) / 65025);
  analogWrite(PIN_BLUE, (uint32_t(b) * br * 4095) / 65025);
  analogWrite(PIN_WHITE, (uint32_t(w) * br * 4095) / 65025);
}

void playSoundEvent(uint8_t eventId) {
  if (!soundEnabled && eventId != 10) return;
  buzzerEvent = eventId; buzzerStep = 0; buzzerStepStart = currentMillis;
}

void getBuzzerStep(uint8_t eventId, uint8_t stepId, uint16_t &freq, uint16_t &dur) {
  freq = 0; dur = 0;
  switch (eventId) {
  case 1: if (stepId == 0) { freq = 1046; dur = 50; } else if (stepId == 1) { freq = 1318; dur = 50; } else if (stepId == 2) { freq = 1568; dur = 60; } break;
  case 2: if (stepId == 0) { freq = 1568; dur = 40; } break;
  case 3: if (stepId == 0) { freq = 1318; dur = 30; } else if (stepId == 1) { freq = 0; dur = 20; } else if (stepId == 2) { freq = 1568; dur = 40; } break;
  case 4: if (stepId == 0) { freq = 1568; dur = 40; } else if (stepId == 1) { freq = 1318; dur = 50; } break;
  case 5: if (stepId == 0) { freq = 440; dur = 80; } break;
  case 6: if (stepId == 0) { freq = 1568; dur = 60; } else if (stepId == 1) { freq = 1318; dur = 60; } else if (stepId == 2) { freq = 1046; dur = 80; } break;
  case 7: if (stepId == 0) { freq = 1174; dur = 40; } else if (stepId == 1) { freq = 1568; dur = 60; } break;
  case 8: if (stepId == 0) { freq = 1318; dur = 30; } break;
  }
}

void updateBuzzer() {
  if (buzzerEvent == 0) { digitalWrite(PIN_BUZZER, LOW); return; }
  uint16_t freq, dur;
  getBuzzerStep(buzzerEvent, buzzerStep, freq, dur);

  if (dur == 0) { buzzerEvent = 0; digitalWrite(PIN_BUZZER, LOW); return; }

  if (currentMillis - buzzerStepStart >= dur) {
    buzzerStep++; buzzerStepStart = currentMillis; buzzerMicros = micros();
    digitalWrite(PIN_BUZZER, LOW); return;
  }

  if (freq > 0) {
    uint32_t halfPeriod = 1000000 / freq / 2;
    if (micros() - buzzerMicros >= halfPeriod) {
      buzzerMicros = micros(); buzzerPinState = !buzzerPinState; digitalWrite(PIN_BUZZER, buzzerPinState);
    }
  } else { digitalWrite(PIN_BUZZER, LOW); }
}

void setupPins() {
  pinMode(PIN_RED, OUTPUT); pinMode(PIN_GREEN, OUTPUT); pinMode(PIN_BLUE, OUTPUT); pinMode(PIN_WHITE, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT); 
  pinMode(PIN_STATUS_GREEN, OUTPUT); pinMode(PIN_STATUS_RED, OUTPUT);
  digitalWrite(PIN_STATUS_GREEN, HIGH); digitalWrite(PIN_STATUS_RED, HIGH); // Common anode, HIGH = OFF
  applyLEDs(0, 0, 0, 0);
}

void resetEffectState() {
  effectStep = 0;
  currentBaseR = currentState.red << 8; currentBaseG = currentState.green << 8; currentBaseB = currentState.blue << 8; currentBaseW = currentState.white << 8;
  baseR = currentState.red; baseG = currentState.green; baseB = currentState.blue; baseW = currentState.white;
  tvCurrentInt = 114 << 8; tvTargetInt = 114 << 8; tvCurrentShift = 255 << 8; tvTargetShift = 255 << 8;
  tvLastSceneChangeTime = 0; tvNextSceneInterval = 0;
  thunderState = 0; thunderStateTimer = 0; thunderStateDuration = 0; thunderFlashIntensity = 0; thunderHasSecondary = false;
  fwState = 0; fwStateTimer = 0; fwStateDuration = 0; fwCrackleCeiling = 0; fwCrackleBright = 0;
  fbState = 0; fbStateTimer = 0; fbStateDuration = 0; fbFaultLevel = 255; fbFaultStep = 0;
  clState = 0; clStateTimer = 0; clStateDuration = 0; clLastHueBucket = 255; clPatternStep = 0;
  cdLayerSlow = 200 << 4; cdLayerMid = 200 << 4; cdLayerFast = 200 << 4;
  cdTargetSlow = 200 << 4; cdTargetMid = 200 << 4; cdTargetFast = 200 << 4;
  cdDipActive = 0; cdDipCooldownEnd = 0; cdLastUpdateMillis = 0;
  fireLayerMajor = 200 << 4; fireLayerMinor = 200 << 4;
  fireTargetMajor = 200 << 4; fireTargetMinor = 200 << 4;
  fireFlareActive = 0; fireFlareCooldownEnd = 0; fireLastUpdateMillis = 0;
  polState = 0; polFlashCount = 0; polFlashOn = false; polLastUpdate = 0;
}

void setup() {
  Serial.begin(115200); // For USB Debugging
  
  analogWriteResolution(12);

  // Initialize BLE
  BLEDevice::init("ElectroBright_C3_V1");
  BLEDevice::setMTU(512);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID_TX, BLECharacteristic::PROPERTY_NOTIFY);
  pTxCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic * pRxCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID_RX, BLECharacteristic::PROPERTY_WRITE);
  pRxCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("Waiting for a client connection to notify...");

  const size_t EEPROM_SIZE = sizeof(SystemState) * (NUM_PRESETS + 1);
  EEPROM.begin(EEPROM_SIZE);
  Serial.print("EEPROM Size: ");
  Serial.println(EEPROM_SIZE);
  setupPins();
  randomSeed(analogRead(A0) ^ millis());

  playSoundEvent(1);

  loadStateFromEEPROM();
  resetEffectState();
}

// ---- EFFECT ENGINES ----
void hsv2rgb(uint16_t hue, uint8_t sat, uint8_t val, uint8_t &r, uint8_t &g, uint8_t &b) {
  if (sat == 0) { r = g = b = val; return; }
  uint8_t sector = hue / 60; uint8_t rel = hue % 60; uint16_t v = val;
  uint16_t p = (v * (255 - sat)) / 255; uint16_t q = (v * (255 - ((sat * rel) / 60))) / 255; uint16_t t = (v * (255 - ((sat * (60 - rel)) / 60))) / 255;
  if (sector == 0 || sector == 6) { r = v; g = t; b = p; } else if (sector == 1) { r = q; g = v; b = p; } else if (sector == 2) { r = p; g = v; b = t; }
  else if (sector == 3) { r = p; g = q; b = v; } else if (sector == 4) { r = t; g = p; b = v; } else { r = v; g = p; b = q; }
}

void modeBlink(uint8_t freq) {
  uint32_t interval = map(freq, 1, 10, 50000, 5000);
  if (((effectStep / interval) % 2) == 0) applyLEDs(baseR, baseG, baseB, baseW); else applyLEDs(0, 0, 0, 0);
}

void modeBreath(uint8_t freq) {
  uint16_t phase = (effectStep / 200) % 512;
  uint16_t val = (phase < 256) ? phase : (511 - phase);
  uint16_t sharpness = map(freq, 1, 10, 1, 4);
  for(int i=0; i<sharpness; i++) val = (uint32_t(val) * val) >> 8;
  val = map(val, 0, 255, 12, 255);
  applyLEDs((uint32_t(baseR) * val) / 255, (uint32_t(baseG) * val) / 255, (uint32_t(baseB) * val) / 255, (uint32_t(baseW) * val) / 255);
}

void modeFireworks(uint8_t speed, uint8_t freq) {
  uint32_t elapsed = currentMillis - fwStateTimer;
  switch (fwState) {
  case 0: // Idle — waiting for next shell
    applyLEDs(2, 1, 0, 0);
    if (elapsed >= fwStateDuration) {
      if (currentState.fireworkColorMode == 1) {
        const uint8_t bucketCount = 5;
        uint8_t bucket = random(bucketCount);
        if (bucket == fwLastHueBucket) bucket = random(bucketCount);
        fwLastHueBucket = bucket;
        uint16_t hue; uint8_t sat = 255;
        switch (bucket) {
          case 0: hue = random(40, 51); break;
          case 1: hue = random(0, 11); break;
          case 2: hue = random(200, 221); sat = 160; break;
          case 3: hue = random(110, 141); break;
          default: hue = random(280, 321); break;
        }
        hsv2rgb(hue, sat, 255, fwR, fwG, fwB);
      } else {
        fwR = currentState.red; fwG = currentState.green; fwB = currentState.blue;
      }
      fwState = 1; fwStateTimer = currentMillis;
      fwStateDuration = map(speed, 1, 10, 400, 100);
    }
    break;
  case 1: { // Rising glow
    uint32_t rampBright = (elapsed < fwStateDuration) ? (uint32_t(60) * elapsed) / fwStateDuration : 60;
    applyLEDs((uint32_t(180) * rampBright) / 255, (uint32_t(80) * rampBright) / 255, (uint32_t(20) * rampBright) / 255, 0);
    if (elapsed >= fwStateDuration) {
      fwState = 2; fwStateTimer = currentMillis; fwStateDuration = 60;
    }
    } break;
  case 2: // Burst flash
    if (elapsed < 30) {
      applyLEDs(255, 240, 220, 180);
    } else {
      applyLEDs(fwR, fwG, fwB, 0);
    }
    if (elapsed >= fwStateDuration) {
      fwCrackleCeiling = 255; fwCrackleBright = 255;
      fwState = 3; fwStateTimer = currentMillis;
      fwStateDuration = random(map(speed, 1, 10, 80, 15), map(speed, 1, 10, 160, 40));
    }
    break;
  case 3: // Crackle decay
    applyLEDs((uint32_t(fwR) * fwCrackleBright) / 255, (uint32_t(fwG) * fwCrackleBright) / 255, (uint32_t(fwB) * fwCrackleBright) / 255, 0);
    if (elapsed >= fwStateDuration) {
      fwCrackleCeiling = (uint16_t(fwCrackleCeiling) * 220) / 256;
      if (fwCrackleCeiling < 18) {
        fwState = 4; fwStateTimer = currentMillis;
        fwStateDuration = map(speed, 1, 10, 500, 150);
        break;
      }
      fwCrackleBright = random(fwCrackleCeiling / 5, fwCrackleCeiling);
      fwStateTimer = currentMillis;
      fwStateDuration = random(map(speed, 1, 10, 80, 15), map(speed, 1, 10, 160, 40));
    }
    break;
  case 4: { // Afterglow — smooth fade to black
    if (elapsed >= fwStateDuration) {
      applyLEDs(0, 0, 0, 0);
      fwState = 0; fwStateTimer = currentMillis;
      fwStateDuration = random(map(freq, 1, 10, 4000, 400), map(freq, 1, 10, 8000, 1000));
    } else {
      uint32_t remain = fwStateDuration - elapsed;
      uint8_t fadeVal = (uint32_t(18) * remain) / fwStateDuration;
      applyLEDs((uint32_t(fwR) * fadeVal) / 255, (uint32_t(fwG) * fadeVal) / 255, (uint32_t(fwB) * fadeVal) / 255, 0);
    }
    } break;
  }
}

void modeTV(uint8_t speed, uint8_t freq) {
  uint32_t dt = currentMillis - tvLastFrameMillis;
  if (dt < 20) return; 
  tvLastFrameMillis = currentMillis;

  static uint16_t currentH = 200 << 8, targetH = 200 << 8, currentS = 50 << 8, targetS = 50 << 8, currentV = 100 << 8, targetV = 100 << 8;

  if (currentMillis - tvLastSceneChangeTime >= tvNextSceneInterval) {
    tvLastSceneChangeTime = currentMillis;
    uint8_t sceneType = random(4);
    if (sceneType == 0) { targetH = random(180, 240) << 8; targetS = random(80, 200) << 8; targetV = random(120, 255) << 8; } 
    else if (sceneType == 1) { targetH = random(10, 40) << 8; targetS = random(100, 180) << 8; targetV = random(100, 220) << 8; } 
    else if (sceneType == 2) { targetH = random(200, 260) << 8; targetS = random(50, 150) << 8; targetV = random(20, 80) << 8; } 
    else { targetH = random(0, 360) << 8; targetS = random(0, 50) << 8; targetV = random(200, 255) << 8; }

    tvNextSceneInterval = random(map(freq, 1, 10, 4000, 400), map(freq, 1, 10, 10000, 1500));
    if (random(100) < 40) { currentH = targetH; currentS = targetS; currentV = targetV; }
  }

  int32_t transitionDiv = map(speed, 1, 10, 1000, 100);
  int32_t stepH = ((int32_t)targetH - currentH) * (int32_t)dt / transitionDiv; if (targetH > currentH && stepH == 0) stepH = 1; else if (targetH < currentH && stepH == 0) stepH = -1; currentH += stepH;
  int32_t stepS = ((int32_t)targetS - currentS) * (int32_t)dt / transitionDiv; if (targetS > currentS && stepS == 0) stepS = 1; else if (targetS < currentS && stepS == 0) stepS = -1; currentS += stepS;
  int32_t stepV = ((int32_t)targetV - currentV) * (int32_t)dt / transitionDiv; if (targetV > currentV && stepV == 0) stepV = 1; else if (targetV < currentV && stepV == 0) stepV = -1; currentV += stepV;

  uint8_t r, g, b; hsv2rgb(currentH >> 8, currentS >> 8, currentV >> 8, r, g, b); applyLEDs(r, g, b, 0);
}

void modeThunder(uint8_t speed, uint8_t freq) {
  uint32_t elapsed = currentMillis - thunderStateTimer;
  switch (thunderState) {
  case 0: applyLEDs(0, 0, 0, 0); if (elapsed >= thunderStateDuration) { thunderState = 1; thunderStateTimer = currentMillis; thunderStateDuration = random(5, 15); thunderHasSecondary = (random(100) < 60); thunderFlashIntensity = 0; } break;
  case 1: { uint16_t target = 255 << 8; if (elapsed >= thunderStateDuration) { thunderFlashIntensity = target; thunderState = 2; thunderStateTimer = currentMillis; thunderStateDuration = random(10, 40); } else { thunderFlashIntensity = (target * elapsed) / thunderStateDuration; } applyLEDs((uint32_t(baseR) * (thunderFlashIntensity >> 8)) / 255, (uint32_t(baseG) * (thunderFlashIntensity >> 8)) / 255, (uint32_t(baseB) * (thunderFlashIntensity >> 8)) / 255, (uint32_t(baseW) * (thunderFlashIntensity >> 8)) / 255); } break;
  case 2: applyLEDs(baseR, baseG, baseB, baseW); if (elapsed >= thunderStateDuration) { thunderState = 3; thunderStateTimer = currentMillis; thunderStateDuration = random(60, 150); thunderFlashIntensity = 255 << 8; } break;
  case 3:
  case 6: { if (elapsed >= thunderStateDuration) { if (thunderHasSecondary) { thunderState = 4; thunderStateTimer = currentMillis; thunderStateDuration = random(15, 60); } else { thunderState = 7; thunderStateTimer = currentMillis; thunderStateDuration = random(50, 150); } } else { uint32_t remain = thunderStateDuration - elapsed; uint32_t curve = (((remain * 255) / thunderStateDuration) * ((remain * 255) / thunderStateDuration)) >> 8; uint16_t val = ((thunderFlashIntensity >> 8) * curve) / 255; applyLEDs((uint32_t(baseR) * val) / 255, (uint32_t(baseG) * val) / 255, (uint32_t(baseB) * val) / 255, (uint32_t(baseW) * val) / 255); } } break;
  case 4: applyLEDs(0, 0, 0, 0); if (elapsed >= thunderStateDuration) { thunderState = 5; thunderStateTimer = currentMillis; thunderStateDuration = random(10, 30); } break;
  case 5: { uint8_t peak = random(120, 255); applyLEDs((uint32_t(baseR) * peak) / 255, (uint32_t(baseG) * peak) / 255, (uint32_t(baseB) * peak) / 255, (uint32_t(baseW) * peak) / 255); if (elapsed >= thunderStateDuration) { thunderState = 6; thunderStateTimer = currentMillis; thunderStateDuration = random(30, 80); thunderFlashIntensity = peak << 8; thunderHasSecondary = (random(100) < 40); } } break;
  case 7: if (elapsed >= thunderStateDuration) { thunderState = 0; thunderStateTimer = currentMillis; thunderStateDuration = random(map(freq, 1, 10, 5000, 500), map(freq, 1, 10, 12000, 1500)); } else applyLEDs(0, 0, 0, 0); break;
  }
}

void modeFaultyBulb(uint8_t speed, uint8_t freq) {
  uint32_t elapsed = currentMillis - fbStateTimer;
  switch (fbState) {
  case 0: { // Steady — bulb mostly on with subtle ripple flicker
    static uint32_t fbFlickerTimer = 0;
    if (currentMillis - fbFlickerTimer >= (uint32_t)random(30, 80)) {
      fbFlickerTimer = currentMillis;
      fbFaultLevel = 247 + random(9); // 247-255: subtle mains-ripple
    }
    applyLEDs((uint32_t(baseR) * fbFaultLevel) / 255, (uint32_t(baseG) * fbFaultLevel) / 255, (uint32_t(baseB) * fbFaultLevel) / 255, (uint32_t(baseW) * fbFaultLevel) / 255);
    if (elapsed >= fbStateDuration) {
      // Pick fault type (weighted random)
      uint8_t roll = random(100);
      if (roll < 45) fbFaultType = 0;       // Quick flicker-out
      else if (roll < 65) fbFaultType = 1;  // Full dropout + struggling restart
      else if (roll < 90) fbFaultType = 2;  // Sputtering dim spell
      else fbFaultType = 3;                 // Rare arc double-flash
      fbFaultStep = 0;
      fbState = 1; fbStateTimer = currentMillis;
      // Set initial sub-step duration based on fault type
      switch (fbFaultType) {
        case 0: fbStateDuration = random(map(speed, 1, 10, 40, 10), map(speed, 1, 10, 80, 20)); break;
        case 1: fbStateDuration = random(map(speed, 1, 10, 400, 100), map(speed, 1, 10, 600, 200)); break;
        case 2: fbStateDuration = random(map(speed, 1, 10, 60, 15), map(speed, 1, 10, 120, 30)); break;
        case 3: fbStateDuration = random(5, 15); break;
      }
    }
    } break;
  case 1: // Running a fault sequence
    switch (fbFaultType) {
    case 0: { // Quick flicker-out: 1-4 rapid drops
      if (elapsed >= fbStateDuration) {
        fbFaultStep++;
        uint8_t maxBlips = 1 + random(4); // 1-4 total blips
        if (fbFaultStep > maxBlips * 2) {
          // Done — return to steady
          fbFaultLevel = 255;
          fbState = 0; fbStateTimer = currentMillis;
          fbStateDuration = random(map(freq, 1, 10, 5000, 500), map(freq, 1, 10, 12000, 1500));
          break;
        }
        fbStateTimer = currentMillis;
        if (fbFaultStep % 2 == 1) {
          // Drop phase
          fbFaultLevel = random(5, 20);
          fbStateDuration = random(map(speed, 1, 10, 40, 10), map(speed, 1, 10, 80, 20));
        } else {
          // Recovery phase
          fbFaultLevel = random(150, 255);
          fbStateDuration = random(map(speed, 1, 10, 30, 8), map(speed, 1, 10, 60, 15));
        }
      }
      applyLEDs((uint32_t(baseR) * fbFaultLevel) / 255, (uint32_t(baseG) * fbFaultLevel) / 255, (uint32_t(baseB) * fbFaultLevel) / 255, (uint32_t(baseW) * fbFaultLevel) / 255);
      } break;
    case 1: { // Full dropout with slow struggling restart
      if (fbFaultStep == 0) {
        // Hard dropout phase
        fbFaultLevel = 0;
        applyLEDs(0, 0, 0, 0);
        if (elapsed >= fbStateDuration) {
          fbFaultStep = 1; fbStateTimer = currentMillis;
          fbStateDuration = random(map(speed, 1, 10, 800, 200), map(speed, 1, 10, 1200, 400));
          fbFaultLevel = 0;
        }
      } else {
        // Struggling restart: jagged climb with occasional backslides
        static uint32_t fbRestartStepTimer = 0;
        if (currentMillis - fbRestartStepTimer >= (uint32_t)random(map(speed, 1, 10, 60, 15), map(speed, 1, 10, 120, 30))) {
          fbRestartStepTimer = currentMillis;
          if (random(100) < 20 && fbFaultLevel > 15) {
            // Occasional backslide
            fbFaultLevel -= random(5, 15);
          } else {
            // Upward jump
            uint8_t jump = random(8, 30);
            if (fbFaultLevel + jump > 255) fbFaultLevel = 255; else fbFaultLevel += jump;
          }
        }
        applyLEDs((uint32_t(baseR) * fbFaultLevel) / 255, (uint32_t(baseG) * fbFaultLevel) / 255, (uint32_t(baseB) * fbFaultLevel) / 255, (uint32_t(baseW) * fbFaultLevel) / 255);
        if (elapsed >= fbStateDuration) {
          fbFaultLevel = 255;
          fbState = 0; fbStateTimer = currentMillis;
          fbStateDuration = random(map(freq, 1, 10, 5000, 500), map(freq, 1, 10, 12000, 1500));
        }
      }
      } break;
    case 2: { // Sputtering dim spell: jitter in a low band
      static uint32_t fbSputterTimer = 0;
      if (currentMillis - fbSputterTimer >= (uint32_t)random(map(speed, 1, 10, 50, 12), map(speed, 1, 10, 100, 25))) {
        fbSputterTimer = currentMillis;
        fbFaultLevel = random(30, 90);
      }
      applyLEDs((uint32_t(baseR) * fbFaultLevel) / 255, (uint32_t(baseG) * fbFaultLevel) / 255, (uint32_t(baseB) * fbFaultLevel) / 255, (uint32_t(baseW) * fbFaultLevel) / 255);
      if (elapsed >= fbStateDuration) {
        fbFaultLevel = 255;
        fbState = 0; fbStateTimer = currentMillis;
        fbStateDuration = random(map(freq, 1, 10, 5000, 500), map(freq, 1, 10, 12000, 1500));
      }
      } break;
    case 3: { // Rare arc double-flash
      if (fbFaultStep == 0) {
        fbFaultLevel = 255;
        applyLEDs(baseR, baseG, baseB, baseW); // hard spike
        if (elapsed >= fbStateDuration) {
          fbFaultStep = 1; fbStateTimer = currentMillis;
          fbStateDuration = random(3, 8); // tiny gap
        }
      } else if (fbFaultStep == 1) {
        fbFaultLevel = random(180, 220); // brief dimmer gap
        applyLEDs((uint32_t(baseR) * fbFaultLevel) / 255, (uint32_t(baseG) * fbFaultLevel) / 255, (uint32_t(baseB) * fbFaultLevel) / 255, (uint32_t(baseW) * fbFaultLevel) / 255);
        if (elapsed >= fbStateDuration) {
          fbFaultStep = 2; fbStateTimer = currentMillis;
          fbStateDuration = random(5, 15); // second spike
        }
      } else if (fbFaultStep == 2) {
        fbFaultLevel = 255;
        applyLEDs(baseR, baseG, baseB, baseW);
        if (elapsed >= fbStateDuration) {
          fbFaultLevel = 255;
          fbState = 0; fbStateTimer = currentMillis;
          fbStateDuration = random(map(freq, 1, 10, 5000, 500), map(freq, 1, 10, 12000, 1500));
        }
      }
      } break;
    }
    break;
  }
}

void modeSingleDynamic(uint8_t freq) {
  uint16_t phase = (effectStep / map(freq, 1, 10, 300, 30)) % 512; uint16_t val = (phase < 256) ? phase : (511 - phase);
  val = (uint32_t(val) * val) >> 8; val = (uint32_t(val) * val) >> 8;
  applyLEDs((uint32_t(baseR) * val) / 255, (uint32_t(baseG) * val) / 255, (uint32_t(baseB) * val) / 255, (uint32_t(baseW) * val) / 255);
}

void modeClubLights(uint8_t speed, uint8_t freq) {
  uint32_t elapsed = currentMillis - clStateTimer;
  switch (clState) {
  case 0: { // Choose next hit
    applyLEDs(0, 0, 0, 0); // brief gap between hits
    if (elapsed >= clStateDuration) {
      // Pick pattern type (weighted random)
      uint8_t roll = random(100);
      if (roll < 30) clPatternType = 0;       // Solid color slam
      else if (roll < 55) clPatternType = 1;  // Strobe burst
      else if (roll < 75) clPatternType = 2;  // Color-to-color snap chain
      else if (roll < 90) clPatternType = 3;  // Blackout snap
      else clPatternType = 4;                 // White strobe flash
      // Pick hit color
      if (clPatternType != 4) { // White strobe always uses white, ignores color mode
        if (currentState.clubColorMode == 1) {
          const uint8_t bucketCount = 6;
          uint8_t bucket = random(bucketCount);
          if (bucket == clLastHueBucket) bucket = random(bucketCount);
          clLastHueBucket = bucket;
          uint16_t hue; uint8_t sat = 255;
          switch (bucket) {
            case 0: hue = random(300, 331); break;         // Hot pink / magenta
            case 1: hue = random(200, 231); break;         // Electric blue
            case 2: hue = random(110, 141); break;         // Laser green
            case 3: hue = random(260, 281); break;         // Vivid purple
            case 4: hue = random(170, 191); break;         // Cyan
            default: clR = 255; clG = 240; clB = 220; clW = 255; sat = 0; break; // White
          }
          if (sat > 0) { hsv2rgb(hue, sat, 255, clR, clG, clB); clW = 0; }
        } else {
          clR = baseR; clG = baseG; clB = baseB; clW = baseW;
        }
      }
      clPatternStep = 0;
      clState = 1; clStateTimer = currentMillis;
      // Set initial sub-step duration
      switch (clPatternType) {
        case 0: clStateDuration = random(map(speed, 1, 10, 200, 40), map(speed, 1, 10, 350, 80)); break;
        case 1: clStateDuration = random(map(speed, 1, 10, 40, 8), map(speed, 1, 10, 80, 18)); break;
        case 2: clStateDuration = random(map(speed, 1, 10, 120, 30), map(speed, 1, 10, 200, 50)); break;
        case 3: clStateDuration = random(map(speed, 1, 10, 250, 60), map(speed, 1, 10, 400, 120)); break;
        case 4: clStateDuration = random(map(speed, 1, 10, 30, 6), map(speed, 1, 10, 60, 12)); break;
      }
    }
    } break;
  case 1: // Playing the current hit
    switch (clPatternType) {
    case 0: // Solid color slam: snap to color, hold, done
      applyLEDs(clR, clG, clB, clW);
      if (elapsed >= clStateDuration) {
        clState = 0; clStateTimer = currentMillis;
        clStateDuration = random(map(freq, 1, 10, 800, 80), map(freq, 1, 10, 1600, 200));
      }
      break;
    case 1: { // Strobe burst: 3-8 rapid on/off flashes
      if (elapsed >= clStateDuration) {
        clPatternStep++;
        uint8_t maxFlashes = 3 + random(6); // 3-8
        if (clPatternStep > maxFlashes * 2) {
          clState = 0; clStateTimer = currentMillis;
          clStateDuration = random(map(freq, 1, 10, 800, 80), map(freq, 1, 10, 1600, 200));
          break;
        }
        clStateTimer = currentMillis;
        clStateDuration = random(map(speed, 1, 10, 40, 8), map(speed, 1, 10, 80, 18));
      }
      if (clPatternStep % 2 == 0) applyLEDs(clR, clG, clB, clW);
      else applyLEDs(0, 0, 0, 0);
      } break;
    case 2: { // Color-to-color snap chain: 2-4 rapid hits
      if (elapsed >= clStateDuration) {
        clPatternStep++;
        uint8_t chainLen = 2 + random(3); // 2-4
        if (clPatternStep >= chainLen) {
          clState = 0; clStateTimer = currentMillis;
          clStateDuration = random(map(freq, 1, 10, 800, 80), map(freq, 1, 10, 1600, 200));
          break;
        }
        // Pick next link color
        if (currentState.clubColorMode == 1) {
          // AUTO: pick a different hue per link
          uint16_t hue = random(360);
          hsv2rgb(hue, 255, 255, clR, clG, clB); clW = 0;
        } else {
          // MANUAL: vary brightness per link instead of hue
          uint8_t bMult = (clPatternStep % 2 == 0) ? 255 : random(60, 140);
          clR = (uint32_t(baseR) * bMult) / 255;
          clG = (uint32_t(baseG) * bMult) / 255;
          clB = (uint32_t(baseB) * bMult) / 255;
          clW = (uint32_t(baseW) * bMult) / 255;
        }
        clStateTimer = currentMillis;
        clStateDuration = random(map(speed, 1, 10, 120, 30), map(speed, 1, 10, 200, 50));
      }
      applyLEDs(clR, clG, clB, clW);
      } break;
    case 3: // Blackout snap: hard cut to off, then back
      if (clPatternStep == 0) {
        applyLEDs(0, 0, 0, 0);
        if (elapsed >= clStateDuration) {
          clPatternStep = 1; clStateTimer = currentMillis;
          clStateDuration = random(map(speed, 1, 10, 60, 15), map(speed, 1, 10, 120, 30));
        }
      } else {
        applyLEDs(clR, clG, clB, clW);
        if (elapsed >= clStateDuration) {
          clState = 0; clStateTimer = currentMillis;
          clStateDuration = random(map(freq, 1, 10, 800, 80), map(freq, 1, 10, 1600, 200));
        }
      }
      break;
    case 4: { // White strobe flash: 1-2 bright white-channel-forward flashes
      // Intentionally ignores MANUAL/AUTO color mode — always white by design
      if (elapsed >= clStateDuration) {
        clPatternStep++;
        uint8_t maxFlashes = 1 + random(2); // 1-2
        if (clPatternStep > maxFlashes * 2) {
          clState = 0; clStateTimer = currentMillis;
          clStateDuration = random(map(freq, 1, 10, 800, 80), map(freq, 1, 10, 1600, 200));
          break;
        }
        clStateTimer = currentMillis;
        clStateDuration = random(map(speed, 1, 10, 30, 6), map(speed, 1, 10, 60, 12));
      }
      if (clPatternStep % 2 == 0) applyLEDs(255, 240, 220, 255);
      else applyLEDs(0, 0, 0, 0);
      } break;
    }
    break;
  }
}

void modeRainbow(uint8_t freq) { uint32_t interval = map(freq, 1, 10, 700, 70); uint8_t r, g, b; hsv2rgb((effectStep / interval) % 360, 255, 255, r, g, b); applyLEDs(r, g, b, 0); }

void modeFire(uint8_t speed, uint8_t freq) {
  if (currentMillis - fireLastUpdateMillis < 25) return;
  fireLastUpdateMillis = currentMillis;

  if (fireFlareActive == 0 && currentMillis > fireFlareCooldownEnd && random(map(freq, 1, 10, 500, 200)) == 0) {
    fireFlareActive = 1;
    fireFlareTimer = currentMillis;
    fireFlareRise = random(30, 80);
    fireFlareDuration = fireFlareRise + random(100, 250);
  }

  if (currentMillis >= fireMajorRetargetMillis) {
    fireTargetMajor = (200 + ((random(0, 121) - 60) * map(freq, 1, 10, 40, 100)) / 100) << 4;
    fireMajorRetargetMillis = currentMillis + random(map(speed, 1, 10, 2500, 500), map(speed, 1, 10, 4000, 1000));
  }
  if (currentMillis >= fireMinorRetargetMillis) {
    fireTargetMinor = (200 + ((random(0, 51) - 25) * map(freq, 1, 10, 40, 100)) / 100) << 4;
    fireMinorRetargetMillis = currentMillis + random(map(speed, 1, 10, 500, 150), map(speed, 1, 10, 800, 250));
  }

  if (fireTargetMajor > fireLayerMajor) fireLayerMajor += (fireTargetMajor - fireLayerMajor) >> 5;
  else fireLayerMajor -= (fireLayerMajor - fireTargetMajor) >> 5;

  if (fireTargetMinor > fireLayerMinor) fireLayerMinor += (fireTargetMinor - fireLayerMinor) >> 3;
  else fireLayerMinor -= (fireLayerMinor - fireTargetMinor) >> 3;

  int16_t baseline = map(freq, 1, 10, 200, 150);
  int16_t washMajor = (fireLayerMajor >> 4) - 200;
  int16_t washMinor = (fireLayerMinor >> 4) - 200;
  int16_t flareBonus = 0;

  if (fireFlareActive == 1) {
    uint32_t elapsed = currentMillis - fireFlareTimer;
    if (elapsed < fireFlareRise) {
      flareBonus = (100 * elapsed) / fireFlareRise;
    } else if (elapsed < fireFlareDuration) {
      uint32_t decay = elapsed - fireFlareRise;
      uint32_t decayTotal = fireFlareDuration - fireFlareRise;
      flareBonus = 100 - ((100 * decay) / decayTotal);
    } else {
      fireFlareActive = 0;
      fireFlareCooldownEnd = currentMillis + random(map(freq, 1, 10, 4000, 2000), map(freq, 1, 10, 8000, 4000));
    }
  }

  int16_t val = baseline + washMajor + washMinor + flareBonus;
  val = constrain(val, map(freq, 1, 10, 140, 70), 255);

  applyLEDs((uint32_t(baseR) * val) / 255, (uint32_t(baseG) * val) / 255,
            (uint32_t(baseB) * val) / 255, (uint32_t(baseW) * val) / 255);
}

void modePolice(uint8_t speed, uint8_t freq) {
  uint32_t flashDuration = map(speed, 1, 10, 150, 40);
  uint32_t pauseDuration = map(speed, 1, 10, 400, 100);
  uint8_t flashesPerBurst = map(freq, 1, 10, 1, 6);
  
  uint32_t currentDuration = (polState == 1 || polState == 3) ? pauseDuration : flashDuration;
  if (currentMillis - polLastUpdate < currentDuration) return;
  polLastUpdate = currentMillis;

  if (polState == 0 || polState == 2) {
    polFlashOn = !polFlashOn;
    if (!polFlashOn) {
      polFlashCount++;
      if (polFlashCount >= flashesPerBurst) {
        polState++; // Move to pause
      }
    }
  } else {
    polState = (polState + 1) % 4;
    polFlashCount = 0;
    polFlashOn = true;
  }

  uint8_t r = 0, g = 0, b = 0, w = 0;
  if (polFlashOn && (polState == 0 || polState == 2)) {
    if (currentState.policeColorMode == 1) {
      if (polState == 0) { r = 255; } else { b = 255; }
    } else {
      if (polState == 0) {
        r = currentState.policeColorAR; g = currentState.policeColorAG; b = currentState.policeColorAB; w = currentState.policeColorAW;
      } else {
        r = currentState.policeColorBR; g = currentState.policeColorBG; b = currentState.policeColorBB; w = currentState.policeColorBW;
      }
    }
  }
  applyLEDs(r, g, b, w);
}

void modeCandle(uint8_t speed, uint8_t freq) {
  if (currentMillis - cdLastUpdateMillis < 20) return;
  cdLastUpdateMillis = currentMillis;

  if (cdDipActive == 0 && currentMillis > cdDipCooldownEnd && random(500) == 0) {
    cdDipActive = 1;
    cdDipTimer = currentMillis;
    cdDipDuration = random(150, 400);
  }

  int16_t val = 0;
  if (cdDipActive == 1) {
    uint32_t elapsed = currentMillis - cdDipTimer;
    if (elapsed >= cdDipDuration) {
      cdDipActive = 0;
      cdDipCooldownEnd = currentMillis + random(6000, 15000);
    }
    val = random(40, 80);
  } else {
    if (currentMillis >= cdSlowRetargetMillis) {
      cdTargetSlow = (200 + ((random(0, 97) - 64) * map(freq, 1, 10, 40, 100)) / 100) << 4;
      cdSlowRetargetMillis = currentMillis + random(map(speed, 1, 10, 600, 300), map(speed, 1, 10, 900, 400));
    }
    if (currentMillis >= cdMidRetargetMillis) {
      cdTargetMid = (200 + ((random(0, 46) - 30) * map(freq, 1, 10, 40, 100)) / 100) << 4;
      cdMidRetargetMillis = currentMillis + random(map(speed, 1, 10, 200, 80), map(speed, 1, 10, 300, 120));
    }
    if (currentMillis >= cdFastRetargetMillis) {
      cdTargetFast = (200 + ((random(0, 31) - 20) * map(freq, 1, 10, 40, 100)) / 100) << 4;
      cdFastRetargetMillis = currentMillis + random(map(speed, 1, 10, 70, 30), map(speed, 1, 10, 100, 40));
    }

    if (cdTargetSlow > cdLayerSlow) cdLayerSlow += (cdTargetSlow - cdLayerSlow) >> 4;
    else cdLayerSlow -= (cdLayerSlow - cdTargetSlow) >> 4;

    if (cdTargetMid > cdLayerMid) cdLayerMid += (cdTargetMid - cdLayerMid) >> 3;
    else cdLayerMid -= (cdLayerMid - cdTargetMid) >> 3;

    if (cdTargetFast > cdLayerFast) cdLayerFast += (cdTargetFast - cdLayerFast) >> 2;
    else cdLayerFast -= (cdLayerFast - cdTargetFast) >> 2;

    int16_t baseline = map(freq, 1, 10, 220, 195);
    int16_t layerSlow = (cdLayerSlow >> 4) - 200;
    int16_t layerMid = (cdLayerMid >> 4) - 200;
    int16_t layerFast = (cdLayerFast >> 4) - 200;
    
    val = baseline + layerSlow + layerMid + layerFast;
    val = constrain(val, map(freq, 1, 10, 170, 100), 255);
  }

  applyLEDs((uint32_t(baseR) * val) / 255, (uint32_t(baseG) * val) / 255,
            (uint32_t(baseB) * val) / 255, (uint32_t(baseW) * val) / 255);
}

void updateEffects() {
  if (sleepMode || currentState.mode == 1) return;

  static uint32_t lastSmoothMillis = 0;
  uint32_t dtSmooth = currentMillis - lastSmoothMillis;
  if (dtSmooth > 0) {
    lastSmoothMillis = currentMillis;
    int32_t diffR = ((int32_t)currentState.red << 8) - currentBaseR; int32_t diffG = ((int32_t)currentState.green << 8) - currentBaseG; int32_t diffB = ((int32_t)currentState.blue << 8) - currentBaseB; int32_t diffW = ((int32_t)currentState.white << 8) - currentBaseW;
    if (dtSmooth >= 200) { currentBaseR = currentState.red << 8; currentBaseG = currentState.green << 8; currentBaseB = currentState.blue << 8; currentBaseW = currentState.white << 8; } 
    else {
      int32_t stepR = (diffR * (int32_t)dtSmooth) / 200; if (diffR > 0 && stepR == 0) stepR = 1; else if (diffR < 0 && stepR == 0) stepR = -1; currentBaseR += stepR;
      int32_t stepG = (diffG * (int32_t)dtSmooth) / 200; if (diffG > 0 && stepG == 0) stepG = 1; else if (diffG < 0 && stepG == 0) stepG = -1; currentBaseG += stepG;
      int32_t stepB = (diffB * (int32_t)dtSmooth) / 200; if (diffB > 0 && stepB == 0) stepB = 1; else if (diffB < 0 && stepB == 0) stepB = -1; currentBaseB += stepB;
      int32_t stepW = (diffW * (int32_t)dtSmooth) / 200; if (diffW > 0 && stepW == 0) stepW = 1; else if (diffW < 0 && stepW == 0) stepW = -1; currentBaseW += stepW;
    }
    baseR = currentBaseR >> 8; baseG = currentBaseG >> 8; baseB = currentBaseB >> 8; baseW = currentBaseW >> 8;
  }

  uint8_t activeSpeed = currentState.modeSpeed[currentState.mode - 1];
  uint8_t activeFreq = currentState.modeFrequency[currentState.mode - 1];

  if (currentState.mode == 4) { modeFireworks(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 5) { modeTV(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 6) { modeThunder(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 7) { modeFaultyBulb(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 9) { modeClubLights(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 11) { modeFire(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 12) { modePolice(activeSpeed, activeFreq); return; }
  else if (currentState.mode == 13) { modeCandle(activeSpeed, activeFreq); return; }

  static uint32_t prevEffectFrameMillis = 0;
  if (currentMillis - prevEffectFrameMillis >= 10) {
    uint32_t dt = currentMillis - prevEffectFrameMillis; prevEffectFrameMillis = currentMillis;
    effectStep += (activeSpeed * activeSpeed) * dt;
    switch (currentState.mode) {
      case 2: modeBlink(activeFreq); break; case 3: modeBreath(activeFreq); break;
      case 8: modeSingleDynamic(activeFreq); break; case 10: modeRainbow(activeFreq); break;
    }
  }
}

// --- PARSER AND BLE HANDLING ---
bool isDigitStrict(char c) { return (c >= '0' && c <= '9'); }
bool parseValuesStrict(const char *str, uint8_t *vals, uint8_t count) {
  const char *ptr = str;
  for (uint8_t i = 0; i < count; i++) {
    if (*ptr == '\0' || !isDigitStrict(*ptr)) return false;
    uint16_t v = 0; while (isDigitStrict(*ptr)) { v = (v * 10) + (*ptr - '0'); ptr++; }
    if (v > 255) return false; vals[i] = (uint8_t)v;
    if (i < count - 1) { if (*ptr != ',') return false; ptr++; }
  }
  return (*ptr == '\0');
}
long atoiStrict(const char *str) {
  if (!isDigitStrict(*str)) return -1;
  long v = 0; while (isDigitStrict(*str)) { v = (v * 10) + (*str - '0'); str++; }
  return (*str == '\0') ? v : -1;
}

uint16_t getPresetAddress(uint8_t id) { return sizeof(SystemState) + (id * sizeof(SystemState)); }

void savePreset(uint8_t id) {
  uint16_t addr = getPresetAddress(id);
  SystemState temp = currentState; temp.magic = EEPROM_MAGIC_BYTE; temp.crc = calculateCRC8(temp);
  SystemState existing; EEPROM.get(addr, existing);
  if (memcmp(&existing, &temp, sizeof(SystemState)) != 0) { EEPROM.put(addr, temp); EEPROM.commit(); }
}

bool loadPreset(uint8_t id) {
  uint16_t addr = getPresetAddress(id); SystemState temp; EEPROM.get(addr, temp);
  if (temp.magic == EEPROM_MAGIC_BYTE && calculateCRC8(temp) == temp.crc) {
    currentState = temp; markColorDirty(); markModeSettingsDirty(); resetEffectState();
    if (currentState.mode == 1) applyLEDs(currentState.red, currentState.green, currentState.blue, currentState.white);
    return true;
  }
  return false;
}

bool deletePreset(uint8_t id) {
  uint16_t addr = getPresetAddress(id); SystemState existing; EEPROM.get(addr, existing);
  if (existing.magic != 0xFFFF) { SystemState temp; temp.magic = 0xFFFF; EEPROM.put(addr, temp); EEPROM.commit(); }
  return true;
}

void sendPresetList() {
  char buf[64];
  int len = snprintf(buf, sizeof(buf), "PRESETS:");
  for (uint8_t i = 0; i < NUM_PRESETS; i++) {
    uint16_t addr = getPresetAddress(i); SystemState temp; EEPROM.get(addr, temp);
    if (temp.magic == EEPROM_MAGIC_BYTE && calculateCRC8(temp) == temp.crc) {
      if (len < sizeof(buf)) len += snprintf(buf + len, sizeof(buf) - len, "%d,", i);
    }
  }
  bleSendString(buf);
}

void sendStatus() {
  uint32_t timerRemainingSec = 0;
  if (timerActive) {
    uint32_t elapsed = currentMillis - timerStartMillis;
    timerRemainingSec = (elapsed < timerDurationMs) ? (timerDurationMs - elapsed) / 1000 : 0;
  }
  char buf[160];
  snprintf(buf, sizeof(buf), "STATUS:%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%lu,%d",
           currentState.red, currentState.green, currentState.blue, currentState.white,
           currentState.brightness, currentState.mode,
           currentState.modeSpeed[currentState.mode - 1], currentState.modeFrequency[currentState.mode - 1],
           currentState.fireworkColorMode, currentState.clubColorMode, currentState.policeColorMode,
           sleepMode ? 1 : 0, timerActive ? 1 : 0, (unsigned long)timerRemainingSec, soundEnabled ? 1 : 0);
  bleSendString(buf);
}

void factoryReset() {
  uint16_t emptyMagic = 0xFFFF, storedMagic;
  bool anyChange = false;
  EEPROM.get(0 + offsetof(SystemState, magic), storedMagic);
  if (storedMagic != emptyMagic) { EEPROM.put(0 + offsetof(SystemState, magic), emptyMagic); anyChange = true; }
  for (uint8_t i = 0; i < NUM_PRESETS; i++) {
    uint16_t addr = getPresetAddress(i); EEPROM.get(addr + offsetof(SystemState, magic), storedMagic);
    if (storedMagic != emptyMagic) { EEPROM.put(addr + offsetof(SystemState, magic), emptyMagic); anyChange = true; }
  }
  if (anyChange) EEPROM.commit();
  setDefaultState(); resetEffectState(); sleepMode = false; timerActive = false; playSoundEvent(6);
}

void parseCommand(char *cmd) {
  if (strncmp(cmd, "RGBW:", 5) == 0) {
    sleepMode = false;
    uint8_t vals[4] = {0};
    if (parseValuesStrict(cmd + 5, vals, 4)) {
      currentState.red = vals[0]; currentState.green = vals[1]; currentState.blue = vals[2]; currentState.white = vals[3];
      applyLEDs(vals[0], vals[1], vals[2], vals[3]);
      markColorDirty();
      bleSendString("OK");
    } else { playSoundEvent(5); bleSendString("ERROR:FORMAT"); }
  } else if (strncmp(cmd, "MODE:", 5) == 0) {
    sleepMode = false;
    long m = atoiStrict(cmd + 5);
    if (m >= 1 && m <= NUM_MODES) {
      currentState.mode = (uint8_t)m; resetEffectState(); markModeSettingsDirty(); playSoundEvent(2);
      currentStatusEvent = STATUS_EVENT_MODE_CHANGE; statusEventStart = currentMillis;
      if (m == 1) applyLEDs(currentState.red, currentState.green, currentState.blue, currentState.white);
      bleSendString("OK");
    } else { playSoundEvent(5); bleSendString("ERROR:MODE_INVALID"); }
  } else if (strncmp(cmd, "SPEED:", 6) == 0) {
    long s = atoiStrict(cmd + 6);
    if (s >= 1 && s <= MAX_SPEED) { currentState.modeSpeed[currentState.mode - 1] = (uint8_t)s; markModeSettingsDirty(); bleSendString("OK"); } 
    else { playSoundEvent(5); bleSendString("ERROR:SPEED_OUT_OF_BOUNDS"); }
  } else if (strncmp(cmd, "BRIGHTNESS:", 11) == 0) {
    sleepMode = false;
    long b = atoiStrict(cmd + 11);
    if (b >= 0 && b <= 255) {
      currentState.brightness = (uint8_t)b; markColorDirty();
      if (currentState.mode == 1) applyLEDs(currentState.red, currentState.green, currentState.blue, currentState.white);
      bleSendString("OK");
    } else { playSoundEvent(5); bleSendString("ERROR:BRIGHTNESS_INVALID"); }
  } else if (strncmp(cmd, "FREQUENCY:", 10) == 0) {
    long f = atoiStrict(cmd + 10);
    if (f >= 1 && f <= 10) { currentState.modeFrequency[currentState.mode - 1] = (uint8_t)f; markModeSettingsDirty(); bleSendString("OK"); } 
    else { playSoundEvent(5); bleSendString("ERROR:FREQUENCY_INVALID"); }
  } else if (strncmp(cmd, "FIREWORK_COLOR_MODE:", 20) == 0) {
    long v = atoiStrict(cmd + 20);
    if (v == 0 || v == 1) {
      currentState.fireworkColorMode = (uint8_t)v;
      markModeSettingsDirty();
      bleSendString("OK");
    } else {
      playSoundEvent(5);
      bleSendString("ERROR:FIREWORK_COLOR_MODE_INVALID");
    }
  } else if (strncmp(cmd, "CLUB_COLOR_MODE:", 16) == 0) {
    long v = atoiStrict(cmd + 16);
    if (v == 0 || v == 1) {
      currentState.clubColorMode = (uint8_t)v;
      markModeSettingsDirty();
      bleSendString("OK");
    } else {
      playSoundEvent(5);
      bleSendString("ERROR:CLUB_COLOR_MODE_INVALID");
    }
  } else if (strncmp(cmd, "POLICE_COLOR_MODE:", 18) == 0) {
    long v = atoiStrict(cmd + 18);
    if (v == 0 || v == 1) {
      currentState.policeColorMode = (uint8_t)v;
      markModeSettingsDirty();
      bleSendString("OK");
    } else {
      playSoundEvent(5);
      bleSendString("ERROR:POLICE_COLOR_MODE_INVALID");
    }
  } else if (strncmp(cmd, "POLICE_COLOR_A:", 15) == 0) {
    uint8_t vals[4] = {0};
    if (parseValuesStrict(cmd + 15, vals, 4)) {
      currentState.policeColorAR = vals[0]; currentState.policeColorAG = vals[1]; currentState.policeColorAB = vals[2]; currentState.policeColorAW = vals[3];
      markModeSettingsDirty();
      bleSendString("OK");
    } else { playSoundEvent(5); bleSendString("ERROR:FORMAT"); }
  } else if (strncmp(cmd, "POLICE_COLOR_B:", 15) == 0) {
    uint8_t vals[4] = {0};
    if (parseValuesStrict(cmd + 15, vals, 4)) {
      currentState.policeColorBR = vals[0]; currentState.policeColorBG = vals[1]; currentState.policeColorBB = vals[2]; currentState.policeColorBW = vals[3];
      markModeSettingsDirty();
      bleSendString("OK");
    } else { playSoundEvent(5); bleSendString("ERROR:FORMAT"); }
  } else if (strcmp(cmd, "MODE_SETTINGS") == 0) {
    char buf[192];
    int len = snprintf(buf, sizeof(buf), "MODE_SETTINGS:");
    for (int i=0; i<NUM_MODES; i++) {
      if (len < 0 || (size_t)len >= sizeof(buf) - 1) break;
      len += snprintf(buf + len, sizeof(buf) - len, "%d,%d", currentState.modeSpeed[i], currentState.modeFrequency[i]);
      if (len < 0) break;
      if (i < NUM_MODES - 1 && (size_t)len < sizeof(buf) - 1) { buf[len++] = ';'; buf[len] = '\0'; }
    }
    bleSendString(buf);
  } else if (strncmp(cmd, "PRESET_SAVE:", 12) == 0) {
    long p = atoiStrict(cmd + 12);
    if (p >= 0 && p < NUM_PRESETS) { savePreset((uint8_t)p); playSoundEvent(3); bleSendString("OK"); } 
    else { playSoundEvent(5); bleSendString("ERROR:PRESET_ID"); }
  } else if (strncmp(cmd, "PRESET_LOAD:", 12) == 0) {
    sleepMode = false;
    long p = atoiStrict(cmd + 12);
    if (p >= 0 && p < NUM_PRESETS) {
      if (loadPreset((uint8_t)p)) { playSoundEvent(4); sendStatus(); } 
      else { playSoundEvent(5); char errBuf[24]; snprintf(errBuf, sizeof(errBuf), "ERROR:PRESET_EMPTY:%d", (int)p); bleSendString(errBuf); }
    } else { playSoundEvent(5); bleSendString("ERROR:PRESET_ID"); }
  } else if (strncmp(cmd, "PRESET_DELETE:", 14) == 0) {
    long p = atoiStrict(cmd + 14);
    if (p >= 0 && p < NUM_PRESETS) {
      if (deletePreset((uint8_t)p)) { playSoundEvent(11); bleSendString("OK"); } 
      else { playSoundEvent(5); bleSendString("ERROR:PRESET_DELETE"); }
    } else { playSoundEvent(5); bleSendString("ERROR:PRESET_ID"); }
  } else if (strcmp(cmd, "PRESET_LIST") == 0) { sendPresetList();
  } else if (strcmp(cmd, "STATUS") == 0) { sendStatus();
  } else if (strcmp(cmd, "PING") == 0) { bleSendString("OK");
  } else if (strcmp(cmd, "INFO") == 0) { bleSendString("INFO:ElectroBright_ESP32C3_BLE");
  } else if (strcmp(cmd, "VERSION") == 0) { bleSendString("VERSION:2.7.5");
  } else if (strncmp(cmd, "MODE_CAPABILITIES:", 18) == 0) {
    long m = atoiStrict(cmd + 18);
    if (m >= 1 && m <= NUM_MODES) {
      if (m == 1) bleSendString("CAPABILITIES:NONE");
      else if (m == 4 || m == 9 || m == 12) bleSendString("CAPABILITIES:SPEED,FREQUENCY,COLOR_MODE");
      else if (m == 2 || m == 3 || m == 8 || m == 10) bleSendString("CAPABILITIES:FREQUENCY");
      else bleSendString("CAPABILITIES:SPEED,FREQUENCY");
    } else { playSoundEvent(5); bleSendString("ERROR:MODE_INVALID"); }
  } else if (strcmp(cmd, "FACTORY_RESET") == 0) { factoryReset(); bleSendString("OK");
  } else if (strncmp(cmd, "TIMER:", 6) == 0) {
    long mins = atoiStrict(cmd + 6);
    const long MAX_TIMER_MINUTES = 1440;
    if (mins > 0 && mins <= MAX_TIMER_MINUTES) { timerActive = true; timerStartMillis = currentMillis; timerDurationMs = (uint32_t)mins * 60000UL; playSoundEvent(7); bleSendString("OK"); } 
    else if (mins == 0) { timerActive = false; playSoundEvent(10); bleSendString("OK"); } 
    else { playSoundEvent(5); bleSendString("ERROR:FORMAT"); }
  } else if (strcmp(cmd, "WAKE") == 0) {
    sleepMode = false;
    resetEffectState();
    if (currentState.mode == 1) applyLEDs(currentState.red, currentState.green, currentState.blue, currentState.white);
    markColorDirty(true);
    playSoundEvent(4);
    bleSendString("OK");
  } else if (strcmp(cmd, "SLEEP") == 0) { sleepMode = true; markColorDirty(true); playSoundEvent(8); bleSendString("OK");
  } else if (strcmp(cmd, "SOUND_ON") == 0) { soundEnabled = true; playSoundEvent(10); bleSendString("OK");
  } else if (strcmp(cmd, "SOUND_OFF") == 0) { soundEnabled = false; bleSendString("OK");
  } else { playSoundEvent(5); bleSendString("ERROR:UNKNOWN_CMD"); }
}

void updateTimer() {
  if (timerActive && currentMillis - timerStartMillis >= timerDurationMs) { timerActive = false; sleepMode = true; markColorDirty(true); playSoundEvent(8); }
}

void updateStatusColorLED() {
  if (sleepMode) {
    digitalWrite(PIN_STATUS_GREEN, HIGH); digitalWrite(PIN_STATUS_RED, HIGH); return;
  }
  uint32_t elapsed = currentMillis - statusEventStart;
  switch (currentStatusEvent) {
    case STATUS_EVENT_NONE:
      digitalWrite(PIN_STATUS_GREEN, HIGH); digitalWrite(PIN_STATUS_RED, HIGH);
      break;
    case STATUS_EVENT_ADVERTISING_BREATHE: {
      if (deviceConnected) { currentStatusEvent = STATUS_EVENT_NONE; break; }
      digitalWrite(PIN_STATUS_RED, HIGH);
      uint32_t phase = elapsed % 2000;
      uint32_t brightness = (phase < 1000) ? phase : (2000 - phase);
      analogWrite(PIN_STATUS_GREEN, 255 - ((brightness * 255) / 1000));
      break;
    }
    case STATUS_EVENT_CONNECT_BLINK: {
      digitalWrite(PIN_STATUS_RED, HIGH);
      if (elapsed < 100) digitalWrite(PIN_STATUS_GREEN, LOW);
      else if (elapsed < 200) digitalWrite(PIN_STATUS_GREEN, HIGH);
      else if (elapsed < 300) digitalWrite(PIN_STATUS_GREEN, LOW);
      else if (elapsed < 400) digitalWrite(PIN_STATUS_GREEN, HIGH);
      else currentStatusEvent = STATUS_EVENT_NONE;
      break;
    }
    case STATUS_EVENT_MODE_CHANGE: {
      digitalWrite(PIN_STATUS_GREEN, HIGH);
      if (elapsed >= 300) { currentStatusEvent = STATUS_EVENT_NONE; digitalWrite(PIN_STATUS_RED, HIGH); }
      else {
        uint32_t brightness = (elapsed < 150) ? elapsed : (300 - elapsed);
        analogWrite(PIN_STATUS_RED, 255 - ((brightness * 255) / 150));
      }
      break;
    }
  }
}

void loop() {
  currentMillis = millis();

  // Handle BLE disconnects and advertising restart
  if (!deviceConnected && oldDeviceConnected) {
      delay(500); // give the bluetooth stack the chance to get things ready
      pServer->startAdvertising(); 
      oldDeviceConnected = deviceConnected;
      currentStatusEvent = STATUS_EVENT_ADVERTISING_BREATHE; statusEventStart = currentMillis;
  }
  if (deviceConnected && !oldDeviceConnected) {
      oldDeviceConnected = deviceConnected;
      currentStatusEvent = STATUS_EVENT_CONNECT_BLINK; statusEventStart = currentMillis;
  }

  char localCmd[BUFFER_SIZE];
  portENTER_CRITICAL(&cmdMux);
  while (cmdQueueCount > 0) {
    strlcpy(localCmd, cmdQueue[cmdQueueHead], BUFFER_SIZE);
    cmdQueueHead = (cmdQueueHead + 1) % CMD_QUEUE_LEN;
    cmdQueueCount--;
    portEXIT_CRITICAL(&cmdMux);
    parseCommand(localCmd);
    portENTER_CRITICAL(&cmdMux);
  }
  portEXIT_CRITICAL(&cmdMux);

  if (currentState.mode == 1) applyLEDs(currentState.red, currentState.green, currentState.blue, currentState.white);
  else updateEffects();

  updateBuzzer();
  updateTimer();
  updateStatusColorLED();
  updateEEPROM();
  delay(1);
}
