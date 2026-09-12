#pragma once

#include "Common.h"

void applyLEDs(uint8_t r, uint8_t g, uint8_t b, uint8_t w);
void resetEffectState();
void updateEffects();
void hsv2rgb(uint16_t hue, uint8_t sat, uint8_t val, uint8_t &r, uint8_t &g, uint8_t &b);
