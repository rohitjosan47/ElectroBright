#pragma once
// Table-driven, allocation-free parser for the text protocol.
//
// Accepted syntax:  NAME            (no arguments)
//                   NAME:a[,b[,c[,d[,e]]]][,]
// Names are case-insensitive and surrounding whitespace is ignored. Numbers
// must be plain unsigned decimal. Field counts and ranges are checked exactly,
// and every failure maps to the same ERROR code the previous firmware used, so
// the app sees familiar replies.
//
// Colour commands (COLOR, POLICE_COLOR_A/B) take exactly one value per channel
// of the fixture's layout; RGBW exists only on layouts with colour LEDs and a
// W LED (the RGBW light).

#include <stdint.h>

#include "../fixture/ChannelLayout.h"

enum class CmdId : uint8_t {
  Rgbw,
  Brightness,
  Mode,
  Speed,
  Frequency,
  FireworkColorMode,
  ClubColorMode,
  PoliceColorMode,
  PoliceColorA,
  PoliceColorB,
  PresetSave,
  PresetLoad,
  PresetDelete,
  PresetList,
  Status,
  ModeSettings,
  ModeSpeed,
  ModeFrequency,
  ModeCapabilities,
  Sleep,
  Wake,
  SoundOn,
  SoundOff,
  Timer,
  FactoryReset,
  Info,
  Version,
  Caps,
  Ping,
  Diag,
  Identify,
};

struct Command {
  CmdId id;
  uint8_t argc;
  int32_t args[kMaxChannels];
};

enum class ParseStatus : uint8_t { Ok, Unknown, Format, Range };

struct ParseResult {
  ParseStatus status;
  Command cmd;
  const char* errorCode;  // e.g. "MODE_INVALID"; valid when status != Ok
};

ParseResult parseCommand(const char* line, const ChannelLayout& layout);
// RGBW layout (the original fixture); kept for tools and tests.
inline ParseResult parseCommand(const char* line) { return parseCommand(line, layouts::kRgbw); }

// Commands where only the most recent value matters; a run of them in one
// batch collapses to the last one.
bool isCoalescible(CmdId id);

// Read-only commands: they only reply and change no state.
bool isQuery(CmdId id);
