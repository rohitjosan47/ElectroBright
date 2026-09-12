// ElectroBright_ESP32C3_BLE.ino
/*
 * Electrobright v6.0 - ESP32-C3 BLE PORT
 * Fully compatible with iOS and Android via BLE UART (NUS)
 */
#include "Storage.h"
#include "LedController.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

StatusColorEvent currentStatusEvent = STATUS_EVENT_ADVERTISING_BREATHE;
uint32_t statusEventStart = 0;

// --- BLE CONFIGURATION (Nordic UART Service) ---
BLEServer *pServer = NULL;
BLECharacteristic * pTxCharacteristic;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// --- STATE VARIABLES ---
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

bool soundEnabled = true;

uint8_t buzzerEvent = 0;
uint8_t buzzerStep = 0;
uint32_t buzzerStepStart = 0;
uint32_t buzzerMicros = 0;
bool buzzerPinState = false;


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
