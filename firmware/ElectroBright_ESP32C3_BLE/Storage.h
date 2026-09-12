#pragma once

#include "Common.h"

uint8_t calculateCRC8(const SystemState &state);
uint16_t getPresetAddress(uint8_t id);
void setDefaultState();
void savePreset(uint8_t id);
bool loadPreset(uint8_t id);
bool deletePreset(uint8_t id);
void loadStateFromEEPROM();
void updateEEPROM(bool force = false);
void factoryReset();
void markColorDirty(bool forceCommit = false);
void markModeSettingsDirty(bool forceCommit = false);
