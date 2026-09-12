#pragma once

#include "Common.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

extern BLEServer *pServer;
extern BLECharacteristic *pTxCharacteristic;

void initBLE();
void startBleAdvertising();
void bleSendString(const char *str);
void bleSendString(const String &str);
void sendPresetList();
void sendStatus();
void parseCommand(char *cmd);
void processBleCommands();
bool isDigitStrict(char c);
bool parseValuesStrict(const char *str, uint8_t *vals, uint8_t count);
long atoiStrict(const char *str);
