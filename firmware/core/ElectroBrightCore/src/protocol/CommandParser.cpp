#include "CommandParser.h"

#include <stddef.h>
#include <string.h>

#include "../config/Config.h"

namespace {

struct Spec {
  const char* name;
  CmdId id;
  uint8_t argc;
  int32_t firstMin, firstMax;  // range of argument 0
  int32_t restMin, restMax;    // range of arguments 1..argc-1
  const char* errorCode;       // reported for both format and range errors
};

constexpr int32_t kModes = cfg::kNumModes;
constexpr int32_t kLvlMin = cfg::kMinLevel;
constexpr int32_t kLvlMax = cfg::kMaxLevel;
constexpr int32_t kPresetMax = cfg::kNumPresets - 1;
constexpr int32_t kTimerMax = static_cast<int32_t>(cfg::kTimerMaxSeconds);

// clang-format off
constexpr Spec kSpecs[] = {
  {"RGBW",                CmdId::Rgbw,              4, 0, 255,        0, 255,       "FORMAT"},
  {"COLOR",               CmdId::Rgbw,              4, 0, 255,        0, 255,       "FORMAT"},
  {"BRIGHTNESS",          CmdId::Brightness,        1, 0, 255,        0, 0,         "BRIGHTNESS_INVALID"},
  {"MODE",                CmdId::Mode,              1, 1, kModes,     0, 0,         "MODE_INVALID"},
  {"SPEED",               CmdId::Speed,             1, kLvlMin, kLvlMax, 0, 0,      "SPEED_OUT_OF_BOUNDS"},
  {"FREQUENCY",           CmdId::Frequency,         1, kLvlMin, kLvlMax, 0, 0,      "FREQUENCY_INVALID"},
  {"FIREWORK_COLOR_MODE", CmdId::FireworkColorMode, 1, 0, 1,          0, 0,         "FIREWORK_COLOR_MODE_INVALID"},
  {"CLUB_COLOR_MODE",     CmdId::ClubColorMode,     1, 0, 1,          0, 0,         "CLUB_COLOR_MODE_INVALID"},
  {"POLICE_COLOR_MODE",   CmdId::PoliceColorMode,   1, 0, 1,          0, 0,         "POLICE_COLOR_MODE_INVALID"},
  {"POLICE_COLOR_A",      CmdId::PoliceColorA,      4, 0, 255,        0, 255,       "FORMAT"},
  {"POLICE_COLOR_B",      CmdId::PoliceColorB,      4, 0, 255,        0, 255,       "FORMAT"},
  {"PRESET_SAVE",         CmdId::PresetSave,        1, 0, kPresetMax, 0, 0,         "PRESET_ID"},
  {"PRESET_LOAD",         CmdId::PresetLoad,        1, 0, kPresetMax, 0, 0,         "PRESET_ID"},
  {"PRESET_DELETE",       CmdId::PresetDelete,      1, 0, kPresetMax, 0, 0,         "PRESET_ID"},
  {"PRESET_LIST",         CmdId::PresetList,        0, 0, 0,          0, 0,         "FORMAT"},
  {"STATUS",              CmdId::Status,            0, 0, 0,          0, 0,         "FORMAT"},
  {"MODE_SETTINGS",       CmdId::ModeSettings,      0, 0, 0,          0, 0,         "FORMAT"},
  {"MODE_SPEED",          CmdId::ModeSpeed,         2, 1, kModes,     kLvlMin, kLvlMax, "MODE_SPEED_INVALID"},
  {"MODE_FREQUENCY",      CmdId::ModeFrequency,     2, 1, kModes,     kLvlMin, kLvlMax, "MODE_FREQUENCY_INVALID"},
  {"MODE_CAPABILITIES",   CmdId::ModeCapabilities,  1, 1, kModes,     0, 0,         "MODE_INVALID"},
  {"SLEEP",               CmdId::Sleep,             0, 0, 0,          0, 0,         "FORMAT"},
  {"WAKE",                CmdId::Wake,              0, 0, 0,          0, 0,         "FORMAT"},
  {"SOUND_ON",            CmdId::SoundOn,           0, 0, 0,          0, 0,         "FORMAT"},
  {"SOUND_OFF",           CmdId::SoundOff,          0, 0, 0,          0, 0,         "FORMAT"},
  {"TIMER",               CmdId::Timer,             1, 0, kTimerMax,  0, 0,         "FORMAT"},
  {"FACTORY_RESET",       CmdId::FactoryReset,      0, 0, 0,          0, 0,         "FORMAT"},
  {"INFO",                CmdId::Info,              0, 0, 0,          0, 0,         "FORMAT"},
  {"VERSION",             CmdId::Version,           0, 0, 0,          0, 0,         "FORMAT"},
  {"CAPS",                CmdId::Caps,              0, 0, 0,          0, 0,         "FORMAT"},
  {"PING",                CmdId::Ping,              0, 0, 0,          0, 0,         "FORMAT"},
  {"DIAG",                CmdId::Diag,              0, 0, 0,          0, 0,         "FORMAT"},
};
// clang-format on

inline bool isSpace(char c) { return c == ' ' || c == '\t'; }
inline bool isDigit(char c) { return c >= '0' && c <= '9'; }
inline char upper(char c) { return (c >= 'a' && c <= 'z') ? static_cast<char>(c - 'a' + 'A') : c; }

// Case-insensitive compare of [s, s+len) with a NUL-terminated upper-case name.
bool nameEquals(const char* s, size_t len, const char* name) {
  size_t i = 0;
  for (; i < len; ++i) {
    if (name[i] == '\0' || upper(s[i]) != name[i]) return false;
  }
  return name[i] == '\0';
}

// Parses one unsigned decimal field in [begin, end), surrounding blanks allowed.
// Returns 0 = ok, 1 = format error, 2 = too large.
int parseField(const char* begin, const char* end, int32_t& out) {
  while (begin < end && isSpace(*begin)) ++begin;
  while (end > begin && isSpace(end[-1])) --end;
  if (begin == end) return 1;
  int64_t v = 0;
  for (const char* p = begin; p < end; ++p) {
    if (!isDigit(*p)) return 1;
    v = v * 10 + (*p - '0');
    if (v > 1000000000LL) return 2;
  }
  out = static_cast<int32_t>(v);
  return 0;
}

ParseResult fail(ParseStatus status, const char* code) {
  ParseResult r{};
  r.status = status;
  r.errorCode = code;
  return r;
}

}  // namespace

ParseResult parseCommand(const char* line) {
  if (line == nullptr) return fail(ParseStatus::Unknown, "UNKNOWN_CMD");

  // Trim the whole line.
  const char* begin = line;
  while (*begin && isSpace(*begin)) ++begin;
  const char* end = begin + strlen(begin);
  while (end > begin && isSpace(end[-1])) --end;

  const char* colon = static_cast<const char*>(memchr(begin, ':', static_cast<size_t>(end - begin)));
  const char* nameEnd = colon ? colon : end;
  while (nameEnd > begin && isSpace(nameEnd[-1])) --nameEnd;
  const size_t nameLen = static_cast<size_t>(nameEnd - begin);

  const Spec* spec = nullptr;
  for (const Spec& s : kSpecs) {
    if (nameEquals(begin, nameLen, s.name)) {
      spec = &s;
      break;
    }
  }
  if (spec == nullptr) return fail(ParseStatus::Unknown, "UNKNOWN_CMD");

  ParseResult r{};
  r.status = ParseStatus::Ok;
  r.errorCode = nullptr;
  r.cmd.id = spec->id;
  r.cmd.argc = spec->argc;

  // Argument text (may be empty).
  const char* args = colon ? colon + 1 : end;
  const char* p = args;
  while (p < end && isSpace(*p)) ++p;
  const bool noArgText = (p == end);

  if (spec->argc == 0) {
    // "STATUS" and "STATUS:" are both fine; "STATUS:5" is not.
    if (!noArgText) return fail(ParseStatus::Format, spec->errorCode);
    return r;
  }
  if (colon == nullptr || noArgText) return fail(ParseStatus::Format, spec->errorCode);

  uint8_t field = 0;
  const char* fieldStart = args;
  for (const char* q = args;; ++q) {
    if (q == end || *q == ',') {
      if (field == spec->argc) {
        // Only a single, empty trailing field (a trailing comma) is tolerated.
        const char* t = fieldStart;
        while (t < q && isSpace(*t)) ++t;
        if (t != q || q != end) return fail(ParseStatus::Format, spec->errorCode);
        break;
      }
      int32_t v = 0;
      const int rc = parseField(fieldStart, q, v);
      if (rc == 1) return fail(ParseStatus::Format, spec->errorCode);
      const int32_t lo = field == 0 ? spec->firstMin : spec->restMin;
      const int32_t hi = field == 0 ? spec->firstMax : spec->restMax;
      if (rc == 2 || v < lo || v > hi) return fail(ParseStatus::Range, spec->errorCode);
      r.cmd.args[field++] = v;
      if (q == end) break;
      fieldStart = q + 1;
    }
  }
  if (field != spec->argc) return fail(ParseStatus::Format, spec->errorCode);
  return r;
}

bool isCoalescible(CmdId id) {
  return id == CmdId::Rgbw || id == CmdId::Brightness || id == CmdId::Speed || id == CmdId::Frequency;
}
