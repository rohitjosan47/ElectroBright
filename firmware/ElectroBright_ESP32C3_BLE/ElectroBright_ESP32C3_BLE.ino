// ElectroBright_ESP32C3_BLE.ino
/*
 * Electrobright v6.0 - ESP32-C3 BLE PORT
 * Fully compatible with iOS and Android via BLE UART (NUS)
 */
#include "Common.h"
#include "Storage.h"
#include "LedController.h"
#include "BleProtocol.h"

StatusColorEvent currentStatusEvent = STATUS_EVENT_ADVERTISING_BREATHE;
uint32_t statusEventStart = 0;

// --- BLE STATE ---
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

bool soundEnabled = true;

uint8_t buzzerEvent = 0;
uint8_t buzzerStep = 0;
uint32_t buzzerStepStart = 0;
uint32_t buzzerMicros = 0;
bool buzzerPinState = false;

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
  initBLE();
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
      startBleAdvertising(); 
      oldDeviceConnected = deviceConnected;
      currentStatusEvent = STATUS_EVENT_ADVERTISING_BREATHE; statusEventStart = currentMillis;
  }
  if (deviceConnected && !oldDeviceConnected) {
      oldDeviceConnected = deviceConnected;
      currentStatusEvent = STATUS_EVENT_CONNECT_BLINK; statusEventStart = currentMillis;
  }

  processBleCommands();

  if (currentState.mode == 1) applyLEDs(currentState.red, currentState.green, currentState.blue, currentState.white);
  else updateEffects();

  updateBuzzer();
  updateTimer();
  updateStatusColorLED();
  updateEEPROM();
  delay(1);
}
