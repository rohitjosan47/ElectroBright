#pragma once
// Table-driven, allocation-free parser for the text protocol.
//
// Accepted syntax:  NAME            (no arguments)
//                   NAME:a[,b[,c[,d]]][,]
// Names are case-insensitive and surrounding whitespace is ignored. Numbers
// must be plain unsigned decimal. Field counts and ranges are checked exactly,
// and every failure maps to the same ERROR code the previous firmware used, so
// the app sees familiar replies.

#include <stdint.h>

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
};

struct Command {
  CmdId id;
  uint8_t argc;
  int32_t args[4];
};

enum class ParseStatus : uint8_t { Ok, Unknown, Format, Range };

struct ParseResult {
  ParseStatus status;
  Command cmd;
  const char* errorCode;  // e.g. "MODE_INVALID"; valid when status != Ok
};

ParseResult parseCommand(const char* line);

// Commands where only the most recent value matters; a run of them in one
// batch collapses to the last one.
bool isCoalescible(CmdId id);
