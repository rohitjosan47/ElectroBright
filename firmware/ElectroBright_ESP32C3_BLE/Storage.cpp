#include "Storage.h"
#include <EEPROM.h>

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

void markColorDirty(bool forceCommit) {
  colorDirty = true; colorDirtyMillis = currentMillis;
  if (forceCommit) updateEEPROM(true);
}

void markModeSettingsDirty(bool forceCommit) {
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

uint16_t getPresetAddress(uint8_t id) {
  return sizeof(SystemState) + (id * sizeof(SystemState));
}

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
