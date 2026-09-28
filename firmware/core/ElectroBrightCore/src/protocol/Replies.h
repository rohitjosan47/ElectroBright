#pragma once
// Formatters for every reply line (exact formats the Flutter app parses).
// All write into caller-provided buffers with snprintf; nothing allocates.
// Return value: number of characters written (excluding NUL).

#include <stddef.h>
#include <stdint.h>

#include "../fixture/ChannelLayout.h"
#include "../fixture/FixtureProfile.h"
#include "../state/DeviceState.h"

struct StatusView {
  const Scene* scene;
  bool sleeping;
  bool timerActive;
  uint32_t timerRemainingSec;
  bool soundEnabled;
  const ChannelLayout* layout = &layouts::kRgbw;  // colours carry one value per channel
};

namespace replies {

// STATUS:<colour>,br,mode,speed,freq,fwCM,clCM,polCM,sleep,timerActive,timerRemaining,sound,
//        <policeA>,<policeB>
// where each <colour> is one value per layout channel: 3n + 11 fields
// (RGBW: r,g,b,w,...,polAr,polAg,polAb,polAw,polBr,polBg,polBb,polBw = 23 fields).
size_t status(char* out, size_t cap, const StatusView& v);

// MODE_SETTINGS:s1,f1;s2,f2;...;s13,f13
size_t modeSettings(char* out, size_t cap, const Scene& s);

// PRESETS:0,3,14,   (trailing comma; "PRESETS:" when empty)
size_t presets(char* out, size_t cap, uint32_t mask);

// CAPABILITIES:NONE | CAPABILITIES:FREQUENCY | CAPABILITIES:SPEED,FREQUENCY[,COLOR_MODE]
size_t capabilities(char* out, size_t cap, uint8_t mode);

// CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,
//      TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=<layout>[,MODES=<hex>]
// TYPES lists every selectable type (its value runs over commas up to the
// next KEY=); LAYOUT is the active one, NONE in setup-needed mode. MODES
// appears only when the layout lacks a mode.
size_t caps(char* out, size_t cap, const FixtureProfile& fixture);

// ERROR:<code>   or   ERROR:PRESET_EMPTY:<id>
size_t error(char* out, size_t cap, const char* code);
size_t presetEmpty(char* out, size_t cap, uint8_t id);

}  // namespace replies
