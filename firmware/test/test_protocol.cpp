// Protocol layer: parser, line assembler, binary frames, reply formats, egress.

#include <string>
#include <vector>

#include "protocol/BinaryFrame.h"
#include "protocol/CommandParser.h"
#include "protocol/Egress.h"
#include "protocol/LineAssembler.h"
#include "protocol/Replies.h"
#include "render/ModeRegistry.h"
#include "TestFramework.h"

// ------------------------------------------------------------------ parser
TEST(parser_accepts_every_app_command) {
  struct Case {
    const char* line;
    CmdId id;
    uint8_t argc;
  };
  const Case cases[] = {
      {"RGBW:255,0,128,7", CmdId::Rgbw, 4},          {"BRIGHTNESS:0", CmdId::Brightness, 1},
      {"MODE:13", CmdId::Mode, 1},                   {"SPEED:10", CmdId::Speed, 1},
      {"FREQUENCY:1", CmdId::Frequency, 1},          {"FIREWORK_COLOR_MODE:1", CmdId::FireworkColorMode, 1},
      {"CLUB_COLOR_MODE:0", CmdId::ClubColorMode, 1}, {"POLICE_COLOR_MODE:1", CmdId::PoliceColorMode, 1},
      {"POLICE_COLOR_A:1,2,3,4", CmdId::PoliceColorA, 4}, {"POLICE_COLOR_B:5,6,7,8", CmdId::PoliceColorB, 4},
      {"PRESET_SAVE:24", CmdId::PresetSave, 1},      {"PRESET_LOAD:0", CmdId::PresetLoad, 1},
      {"PRESET_DELETE:3", CmdId::PresetDelete, 1},   {"PRESET_LIST", CmdId::PresetList, 0},
      {"STATUS", CmdId::Status, 0},                  {"MODE_SETTINGS", CmdId::ModeSettings, 0},
      {"SLEEP", CmdId::Sleep, 0},                    {"WAKE", CmdId::Wake, 0},
      {"SOUND_ON", CmdId::SoundOn, 0},               {"SOUND_OFF", CmdId::SoundOff, 0},
      {"TIMER:30", CmdId::Timer, 1},                 {"TIMER:0", CmdId::Timer, 1},
      {"FACTORY_RESET", CmdId::FactoryReset, 0},     {"INFO", CmdId::Info, 0},
      {"VERSION", CmdId::Version, 0},                {"CAPS", CmdId::Caps, 0},
      {"PING", CmdId::Ping, 0},                      {"DIAG", CmdId::Diag, 0},
      {"MODE_SPEED:4,7", CmdId::ModeSpeed, 2},       {"MODE_FREQUENCY:13,10", CmdId::ModeFrequency, 2},
      {"MODE_CAPABILITIES:9", CmdId::ModeCapabilities, 1}, {"COLOR:1,2,3,4", CmdId::Rgbw, 4},
  };
  for (const Case& c : cases) {
    const ParseResult r = parseCommand(c.line);
    if (r.status != ParseStatus::Ok) tf::fail(__FILE__, __LINE__, std::string("rejected ") + c.line);
    CHECK(r.cmd.id == c.id);
    CHECK_EQ(r.cmd.argc, c.argc);
  }
  const ParseResult r = parseCommand("RGBW:255,0,128,7");
  CHECK_EQ(r.cmd.args[0], 255);
  CHECK_EQ(r.cmd.args[2], 128);
  CHECK_EQ(r.cmd.args[3], 7);
}

TEST(parser_is_tolerant_of_case_whitespace_and_trailing_comma) {
  CHECK(parseCommand("  status  ").status == ParseStatus::Ok);
  CHECK(parseCommand("Mode : 3").status == ParseStatus::Ok);
  CHECK(parseCommand("RGBW: 1 , 2 ,3,4").status == ParseStatus::Ok);
  CHECK(parseCommand("RGBW:1,2,3,4,").status == ParseStatus::Ok);
  CHECK(parseCommand("STATUS:").status == ParseStatus::Ok);
  CHECK_EQ(parseCommand("mode:7").cmd.args[0], 7);
}

TEST(parser_rejects_malformed_input_with_legacy_codes) {
  struct Case {
    const char* line;
    ParseStatus status;
    const char* code;
  };
  const Case cases[] = {
      {"RGBW:1,2,3", ParseStatus::Format, "FORMAT"},
      {"RGBW:1,2,3,4,5", ParseStatus::Format, "FORMAT"},
      {"RGBW:1,2,3,4,,", ParseStatus::Format, "FORMAT"},
      {"RGBW:256,0,0,0", ParseStatus::Range, "FORMAT"},
      {"RGBW:-1,0,0,0", ParseStatus::Format, "FORMAT"},
      {"RGBW:a,b,c,d", ParseStatus::Format, "FORMAT"},
      {"RGBW", ParseStatus::Format, "FORMAT"},
      {"MODE:0", ParseStatus::Range, "MODE_INVALID"},
      {"MODE:14", ParseStatus::Range, "MODE_INVALID"},
      {"MODE:", ParseStatus::Format, "MODE_INVALID"},
      {"SPEED:11", ParseStatus::Range, "SPEED_OUT_OF_BOUNDS"},
      {"FREQUENCY:0", ParseStatus::Range, "FREQUENCY_INVALID"},
      {"BRIGHTNESS:999999999999", ParseStatus::Range, "BRIGHTNESS_INVALID"},
      {"PRESET_LOAD:25", ParseStatus::Range, "PRESET_ID"},
      {"TIMER:86401", ParseStatus::Range, "FORMAT"},
      {"CLUB_COLOR_MODE:2", ParseStatus::Range, "CLUB_COLOR_MODE_INVALID"},
      {"MODE_SPEED:14,5", ParseStatus::Range, "MODE_SPEED_INVALID"},
      {"STATUS:1", ParseStatus::Format, "FORMAT"},
      {"HELLO", ParseStatus::Unknown, "UNKNOWN_CMD"},
      {"", ParseStatus::Unknown, "UNKNOWN_CMD"},
      {"RGBWX:1,2,3,4", ParseStatus::Unknown, "UNKNOWN_CMD"},
  };
  for (const Case& c : cases) {
    const ParseResult r = parseCommand(c.line);
    if (r.status != c.status) tf::fail(__FILE__, __LINE__, std::string("wrong status for ") + c.line);
    if (r.status != ParseStatus::Ok) CHECK_STR(r.errorCode, c.code);
  }
}

TEST(parser_coalescible_set) {
  CHECK(isCoalescible(CmdId::Rgbw));
  CHECK(isCoalescible(CmdId::Brightness));
  CHECK(isCoalescible(CmdId::Speed));
  CHECK(isCoalescible(CmdId::Frequency));
  CHECK(!isCoalescible(CmdId::Mode));
  CHECK(!isCoalescible(CmdId::PresetSave));
}

// ---------------------------------------------------------------- assembler
static std::vector<std::string> feedAll(LineAssembler& la, const std::string& bytes) {
  std::vector<std::string> out;
  la.feed(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(),
          [&](const char* line, size_t) { out.push_back(line); });
  return out;
}

TEST(assembler_handles_all_terminators_and_fragments) {
  LineAssembler la;
  auto a = feedAll(la, "STATUS\nMODE:3\r\nPING\r");
  CHECK_EQ(a.size(), 3u);
  CHECK_STR(a[0], "STATUS");
  CHECK_STR(a[1], "MODE:3");
  CHECK_STR(a[2], "PING");

  auto b = feedAll(la, "RGB");
  CHECK(b.empty());
  b = feedAll(la, "W:1,2");
  CHECK(b.empty());
  b = feedAll(la, ",3,4\n");
  CHECK_EQ(b.size(), 1u);
  CHECK_STR(b[0], "RGBW:1,2,3,4");

  CHECK(feedAll(la, "\n\n\r\n").empty());  // blank lines ignored
}

TEST(assembler_discards_overlong_lines_entirely) {
  LineAssembler la;
  std::string longLine(cfg::kMaxLineLength + 20, 'A');
  auto r = feedAll(la, longLine + "\nSTATUS\n");
  CHECK_EQ(r.size(), 1u);
  CHECK_STR(r[0], "STATUS");
  CHECK_EQ(la.counters().overflows, 1u);
  // Exactly at the limit is fine.
  std::string exact(cfg::kMaxLineLength, 'B');
  r = feedAll(la, exact + "\n");
  CHECK_EQ(r.size(), 1u);
}

TEST(assembler_rejects_binary_garbage_lines) {
  LineAssembler la;
  std::string bad = "MO";
  bad.push_back(static_cast<char>(0x01));
  bad += "DE:3\nPING\n";
  auto r = feedAll(la, bad);
  CHECK_EQ(r.size(), 1u);
  CHECK_STR(r[0], "PING");
  CHECK_EQ(la.counters().rejected, 1u);
}

// ------------------------------------------------------------------- binary
TEST(binary_frames_round_trip_and_validate) {
  uint8_t pkt[8];
  binframe::encode8(7, {255, 128, 0, 30}, 100, pkt);
  ColorFrame f{};
  CHECK(binframe::isCandidate(pkt, 8));
  CHECK(binframe::decode(pkt, 8, f));
  CHECK(f.hasSeq);
  CHECK_EQ(f.seq, 7);
  CHECK_EQ(f.color.r, 255);
  CHECK_EQ(f.color.w, 30);
  CHECK_EQ(f.brightness, 100);

  pkt[3] ^= 1;  // corrupt
  CHECK(!binframe::decode(pkt, 8, f));

  const uint8_t legacy7[] = {0xAA, 1, 2, 3, 4, 5, static_cast<uint8_t>(1 ^ 2 ^ 3 ^ 4 ^ 5 ^ 0x55)};
  CHECK(binframe::decode(legacy7, 7, f));
  CHECK(f.hasBrightness);
  CHECK_EQ(f.brightness, 5);
  const uint8_t legacy6[] = {0xAA, 9, 8, 7, 6, static_cast<uint8_t>(9 ^ 8 ^ 7 ^ 6 ^ 0x55)};
  CHECK(binframe::decode(legacy6, 6, f));
  CHECK(!f.hasBrightness);
  CHECK_EQ(f.color.r, 9);

  const uint8_t text[] = {'S', 'T', 'A', 'T', 'U', 'S'};
  CHECK(!binframe::isCandidate(text, 6));
}

// ------------------------------------------------------------------ replies
TEST(status_reply_has_exact_23_field_format) {
  Scene s = state::defaultScene();
  s.color = {10, 20, 30, 40};
  s.brightness = 200;
  s.mode = 3;
  s.speed[2] = 7;
  s.freq[2] = 9;
  char buf[256];
  StatusView v{&s, true, true, 125, false};
  replies::status(buf, sizeof(buf), v);
  CHECK_STR(buf, "STATUS:10,20,30,40,200,3,7,9,0,0,1,1,1,125,0,255,165,0,0,0,0,0,255");
}

TEST(mode_settings_and_presets_replies) {
  Scene s = state::defaultScene();
  s.speed[0] = 1;
  s.freq[12] = 10;
  char buf[256];
  replies::modeSettings(buf, sizeof(buf), s);
  CHECK_STR(buf, "MODE_SETTINGS:1,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,10");
  replies::presets(buf, sizeof(buf), 0);
  CHECK_STR(buf, "PRESETS:");
  replies::presets(buf, sizeof(buf), (1u << 0) | (1u << 3) | (1u << 24));
  CHECK_STR(buf, "PRESETS:0,3,24,");
  replies::presetEmpty(buf, sizeof(buf), 12);
  CHECK_STR(buf, "ERROR:PRESET_EMPTY:12");
}

TEST(capabilities_match_app_mode_table) {
  char buf[64];
  const char* expected[cfg::kNumModes] = {
      "CAPABILITIES:NONE",
      "CAPABILITIES:FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY,COLOR_MODE",
      "CAPABILITIES:SPEED,FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY,COLOR_MODE",
      "CAPABILITIES:FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY",
      "CAPABILITIES:SPEED,FREQUENCY,COLOR_MODE",
      "CAPABILITIES:SPEED,FREQUENCY",
  };
  for (uint8_t m = 1; m <= cfg::kNumModes; ++m) {
    replies::capabilities(buf, sizeof(buf), m);
    CHECK_STR(buf, expected[m - 1]);
    // Every exposed slider has a UI name.
    const ModeInfo& info = modeInfo(m);
    CHECK(!info.hasSpeed || info.speedLabel != nullptr);
    CHECK(!info.hasFrequency || info.frequencyLabel != nullptr);
  }
}

// ------------------------------------------------------------------- egress
TEST(egress_packs_lines_and_chunks_to_mtu) {
  Egress e;
  e.push("OK");
  e.push("VERSION:3.0.0");
  std::string wire;
  int notifications = 0;
  e.flush(20, [&](const uint8_t* d, size_t n) {
    wire.append(reinterpret_cast<const char*>(d), n);
    ++notifications;
    return true;
  });
  CHECK_STR(wire, "OK\nVERSION:3.0.0\n");
  CHECK_EQ(notifications, 1);  // 17 bytes fit in one 20-byte notification

  std::string longLine(100, 'X');
  e.push(longLine.c_str());
  wire.clear();
  notifications = 0;
  e.flush(20, [&](const uint8_t* d, size_t n) {
    wire.append(reinterpret_cast<const char*>(d), n);
    ++notifications;
    return true;
  });
  CHECK_EQ(notifications, 6);  // 101 bytes / 20
  CHECK_STR(wire, longLine + "\n");
}

TEST(egress_retries_when_stack_is_busy) {
  Egress e;
  e.push("STATUS:1");
  size_t sent = e.flush(100, [](const uint8_t*, size_t) { return false; });
  CHECK_EQ(sent, 0u);
  CHECK_EQ(e.pending(), 9u);
  std::string wire;
  e.flush(100, [&](const uint8_t* d, size_t n) {
    wire.append(reinterpret_cast<const char*>(d), n);
    return true;
  });
  CHECK_STR(wire, "STATUS:1\n");
  CHECK_EQ(e.pending(), 0u);
}

TEST(egress_drops_oldest_whole_lines_when_full) {
  Egress e;
  std::string line(99, 'L');  // 100 bytes with newline
  for (int i = 0; i < 12; ++i) {
    line[0] = static_cast<char>('a' + i);
    e.push(line.c_str());
  }
  CHECK(e.pending() <= cfg::kEgressBytes);
  CHECK(e.drops() > 0);
  std::string wire;
  e.flush(512, [&](const uint8_t* d, size_t n) {
    wire.append(reinterpret_cast<const char*>(d), n);
    return true;
  });
  CHECK(wire[0] != 'a');                     // the oldest line was evicted
  CHECK_EQ(wire.size() % 100, 0u);           // only whole lines remain
  CHECK(wire.find('l') != std::string::npos);  // the newest line survived
}
