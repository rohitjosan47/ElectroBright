// The RGBCCT fixture (fixtures/ElectroBright_RGBCCT): the shared core with R, G,
// B for colours plus cool white (CW) and warm white (WW). Protocol widths,
// identity, defaults, persistence and five-channel rendering.

#include <string.h>

#include <initializer_list>
#include <string>
#include <vector>

#include "Fakes.h"
#include "Fixtures.h"
#include "TestFramework.h"
#include "fwsim/SimDevice.h"
#include "protocol/BinaryFrame.h"
#include "render/RenderEngine.h"
#include "state/SceneCodec.h"

namespace {

const FixtureProfile& kCct = profiles::kRgbcct;
constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;
constexpr int kR = 0, kG = 1, kB = 2, kCw = 3, kWw = 4;  // duty order = wire order
constexpr const char* kDefaultStatus =
    "STATUS:0,0,0,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,0,255,255";

size_t fieldCount(const std::string& line) {
  const size_t colon = line.find(':');
  if (colon == std::string::npos) return 0;
  size_t n = 1;
  for (size_t i = colon + 1; i < line.size(); ++i) n += line[i] == ',';
  return n;
}

void writeText(SimDevice& d, const char* s) { d.write(reinterpret_cast<const uint8_t*>(s), strlen(s)); }

std::string received(SimDevice& d) {
  std::string s;
  for (const auto& n : d.takeNotifications()) s.append(n.begin(), n.end());
  return s;
}

void connectAndSubscribe(SimDevice& d) {
  d.boot();
  d.connect();
  d.setMtu(247);
  d.setSubscribed(true);
  d.pass();
  d.takeSounds();
}

std::string ask(SimDevice& d, const char* line) {
  writeText(d, line);
  d.pass();
  return received(d);
}

RenderParams paramsFor(uint8_t mode, Color8 color) {
  RenderParams p{};
  p.scene = state::defaultScene(kCct.defaults);
  p.scene.mode = mode;
  p.scene.color = color;
  p.fadeMs = cfg::kSleepFadeMs;
  return p;
}

}  // namespace

// ---- Identity and text protocol -------------------------------------------------------

TEST(rgbcct_reports_its_identity_and_layout) {
  Rig r(kCct);
  r.send("INFO");
  r.send("VERSION");
  r.send("CAPS");
  CHECK_STR(r.env.lines[0], "INFO:EB-C3-RGBCCT-V1");
  CHECK_STR(r.env.lines[1], std::string("VERSION:") + cfg::kFirmwareVersion);
  CHECK_STR(r.env.lines[2], "CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=RGBCCT,OTA=0");
}

TEST(rgbcct_status_has_26_fields_and_white_defaults) {
  Rig r(kCct);
  r.send("STATUS");
  CHECK_STR(r.env.last(), kDefaultStatus);
  CHECK_EQ(fieldCount(r.env.last()), size_t{26});
}

TEST(rgbcct_color_takes_exactly_five_values) {
  Rig r(kCct);
  r.send("COLOR:10,20,30,40,50");
  CHECK(r.env.lines.empty());  // silent on success
  CHECK(r.core.scene().color == (Color8{10, 20, 30, 40, 50}));
  r.send("COLOR:1,2,3,4");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:1,2,3,4,5,6");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:1,2,3,4,256");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("STATUS");
  CHECK_EQ(r.env.last().rfind("STATUS:10,20,30,40,50,", 0), size_t{0});
}

TEST(rgbcct_has_no_rgbw_command) {
  Rig r(kCct);
  r.send("RGBW:1,2,3,4");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  r.send("RGBW:1,2,3,4,5");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
}

TEST(rgbcct_police_colours_take_five_values) {
  Rig r(kCct);
  r.send("POLICE_COLOR_A:1,2,3,4,5");
  CHECK_STR(r.env.last(), "OK");
  r.send("POLICE_COLOR_B:6,7,8,9");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("POLICE_COLOR_B:60,70,80,90,100");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  const std::string s = r.env.last();
  CHECK_STR(s.substr(s.size() - 26), ",1,2,3,4,5,60,70,80,90,100");
}

TEST(rgbcct_colour_commands_coalesce) {
  Rig r(kCct);
  const char* lines[] = {"COLOR:1,1,1,1,1", "COLOR:2,2,2,2,2", "COLOR:3,3,3,3,9"};
  r.core.processLines(lines, 3, r.now);
  CHECK(r.core.scene().color == (Color8{3, 3, 3, 3, 9}));
  CHECK_EQ(Stats::get(r.stats.coalesced), 2u);
}

// ---- Binary frames --------------------------------------------------------------------

TEST(rgbcct_binary_frame_is_nine_bytes_with_its_own_salt) {
  uint8_t f[binframe::kMaxFrame];
  const size_t n = binframe::encode(7, layouts::kRgbcct, {10, 20, 30, 40, 50}, 99, f);
  CHECK_EQ(n, size_t{9});
  CHECK_EQ(f[0], 0xAA);
  CHECK_EQ(f[1], 7);
  CHECK_EQ(f[5], 40);
  CHECK_EQ(f[6], 50);
  CHECK_EQ(f[7], 99);
  CHECK_EQ(f[8], static_cast<uint8_t>(7 ^ 10 ^ 20 ^ 30 ^ 40 ^ 50 ^ 99 ^ 0x50));
  ColorFrame c{};
  CHECK(binframe::decode(f, n, layouts::kRgbcct, false, c));
  CHECK(c.color == (Color8{10, 20, 30, 40, 50}) && c.brightness == 99 && c.seq == 7);
}

TEST(rgbcct_applies_frames_and_rejects_other_fixtures_frames) {
  SimDevice d(kCct);
  connectAndSubscribe(d);
  uint8_t f[binframe::kMaxFrame];
  binframe::encode(0, layouts::kRgbcct, {1, 2, 3, 4, 5}, 128, f);
  d.write(f, 9);
  d.pass();
  CHECK(d.core().scene().color == (Color8{1, 2, 3, 4, 5}));
  CHECK_EQ(d.core().scene().brightness, 128);

  uint8_t rgbw[8];
  binframe::encode8(1, {9, 9, 9, 9}, 200, rgbw);
  d.write(rgbw, 8);
  uint8_t rgb[binframe::kMaxFrame];
  binframe::encode(2, layouts::kRgb, {9, 9, 9, 0}, 200, rgb);
  d.write(rgb, 7);
  const uint8_t legacy6[6] = {0xAA, 5, 6, 7, 8, static_cast<uint8_t>(5 ^ 6 ^ 7 ^ 8 ^ 0x55)};
  d.write(legacy6, 6);
  d.pass();
  CHECK(d.core().scene().color == (Color8{1, 2, 3, 4, 5}));
  CHECK_EQ(Stats::get(d.stats().binaryBad), 3u);
  CHECK_STR(ask(d, "PING\n"), "OK\n");
  CHECK_EQ(Stats::get(d.stats().rxRejectedBytes), 0u);
}

TEST(rgbcct_frames_never_wake_a_sleeping_light) {
  SimDevice d(kCct);
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "SLEEP\n"), "OK\n");
  uint8_t f[binframe::kMaxFrame];
  binframe::encode(0, layouts::kRgbcct, {0, 0, 0, 10, 200}, 50, f);
  d.write(f, 9);
  d.pass();
  CHECK(d.core().sleeping());
  CHECK_EQ(d.core().scene().color.ww, 200);
}

// ---- Defaults and persistence -----------------------------------------------------------

TEST(rgbcct_factory_reset_restores_white_defaults) {
  Rig r(kCct);
  r.send("COLOR:1,2,3,4,5");
  r.send("POLICE_COLOR_B:9,9,9,9,9");
  r.send("FACTORY_RESET");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  CHECK_STR(r.env.last(), kDefaultStatus);
}

TEST(rgbcct_records_carry_warm_white_and_reject_other_formats) {
  CHECK_EQ(scenecodec::recordSize(layouts::kRgbcct), size_t{47});
  Scene s = state::defaultScene(kCct.defaults);
  s.color = {1, 2, 3, 4, 5};
  s.policeA = {6, 7, 8, 9, 10};
  s.policeB = {11, 12, 13, 14, 15};
  uint8_t rec[scenecodec::kMaxRecord];
  const size_t n = scenecodec::pack(s, layouts::kRgbcct, rec);
  CHECK_EQ(n, size_t{47});
  CHECK_EQ(rec[44], 5);
  CHECK_EQ(rec[45], 10);
  CHECK_EQ(rec[46], 15);
  Scene back{};
  CHECK(scenecodec::unpack(rec, n, layouts::kRgbcct, back));
  CHECK(memcmp(&back, &s, sizeof(Scene)) == 0);
  // A 44-byte record (RGBW / RGB flash) is not an RGBCCT record.
  CHECK(!scenecodec::unpack(rec, 44, layouts::kRgbcct, back));

  MockKv kv;
  Stats st;
  kv.data["scene"] = std::vector<uint8_t>(rec, rec + 44);
  StateStore store(kv, st, kCct);
  Scene loaded;
  Settings set;
  store.load(loaded, set);
  CHECK(loaded.color == kCct.defaults.color);
}

TEST(rgbcct_presets_and_scene_survive_a_power_cycle) {
  SimDevice d(kCct);
  connectAndSubscribe(d);
  ask(d, "COLOR:0,0,0,40,220\nMODE:13\nPOLICE_COLOR_A:1,2,3,4,5\n");
  CHECK_STR(ask(d, "PRESET_SAVE:7\n"), "OK\n");
  ask(d, "COLOR:9,9,9,9,9\nMODE:2\n");
  CHECK_STR(ask(d, "PRESET_LOAD:7\n"),
            "STATUS:0,0,0,40,220,255,13,5,5,0,0,1,0,0,0,1,1,2,3,4,5,0,0,0,255,255\n");
  ask(d, "COLOR:0,0,0,0,77\n");
  d.advance(cfg::kPersistMaxLatencyMs + 1000);
  CHECK_EQ(d.flash().data["scene"].size(), size_t{47});
  CHECK_EQ(d.flash().data["p07"].size(), size_t{47});

  d.reboot();
  d.connect();
  d.setMtu(247);
  d.setSubscribed(true);
  d.pass();
  CHECK_STR(ask(d, "PRESET_LIST\n"), "PRESETS:7,\n");
  CHECK_EQ(ask(d, "STATUS\n").rfind("STATUS:0,0,0,0,77,", 0), size_t{0});
  CHECK_EQ(ask(d, "PRESET_LOAD:7\n").rfind("STATUS:0,0,0,40,220,", 0), size_t{0});
}

TEST(rgbcct_status_is_chunked_to_the_mtu) {
  SimDevice d(kCct);
  d.boot();
  d.connect();  // MTU 23 -> 20-byte notifications
  d.setSubscribed(true);
  d.pass();
  writeText(d, "STATUS\n");
  d.pass();
  std::string all;
  for (const auto& c : d.takeNotifications()) {
    CHECK(c.size() <= 20);
    all.append(c.begin(), c.end());
  }
  CHECK_STR(all, std::string(kDefaultStatus) + "\n");
}

// ---- Rendering ----------------------------------------------------------------------------

TEST(rgbcct_every_mode_renders_five_bounded_channels_and_sleeps_dark) {
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    for (uint8_t cm = 0; cm <= 1; ++cm) {
      RenderEngine engine(0xABCu + mode, layouts::kRgbcct, kCct.whiteMix);
      RenderParams p = paramsFor(mode, kCct.defaults.color);
      p.scene.fireworkColorMode = p.scene.clubColorMode = p.scene.policeColorMode = cm;
      uint16_t duty[5];  // exactly five: ASan catches any sixth write
      uint32_t now = 0;
      uint32_t lit = 0;
      for (int i = 0; i < 2000; ++i, now += kFrameMs) {
        engine.frame(p, now, duty);
        for (uint16_t d : duty) CHECK(d <= cfg::kPwmMaxDuty);
        lit += (duty[0] | duty[1] | duty[2] | duty[3] | duty[4]) != 0;
      }
      CHECK(lit > 0);
      p.sleeping = 1;
      for (int i = 0; i < 200; ++i, now += kFrameMs) engine.frame(p, now, duty);
      CHECK_EQ(duty[0] + duty[1] + duty[2] + duty[3] + duty[4], 0);
    }
  }
}

TEST(rgbcct_solid_whites_drive_only_their_own_leds) {
  for (const Color8 c : {Color8{0, 0, 0, 0, 255}, Color8{0, 0, 0, 255, 0}, Color8{0, 0, 0, 128, 64}}) {
    RenderEngine engine(1u, layouts::kRgbcct);
    RenderParams p = paramsFor(1, c);
    uint16_t duty[5];
    uint32_t now = 0;
    for (int i = 0; i < 400; ++i, now += kFrameMs) engine.frame(p, now, duty);
    CHECK_EQ(duty[kR] + duty[kG] + duty[kB], 0);
    CHECK_EQ(duty[kCw] > 0, c.w > 0);
    CHECK_EQ(duty[kWw] > 0, c.ww > 0);
    if (c.w == 255) CHECK_EQ(duty[kCw], cfg::kPwmMaxDuty);
    if (c.ww == 255) CHECK_EQ(duty[kWw], cfg::kPwmMaxDuty);
  }
}

TEST(rgbcct_warm_and_cool_white_behave_identically_in_every_mode) {
  // A pure warm-white scene must drive the WW LED exactly like a pure
  // cool-white scene drives the CW LED: the second white slot is carried
  // through smoothing, effects, crossfades, brightness and fades unchanged.
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    RenderEngine cool(500u + mode, layouts::kRgbcct);
    RenderEngine warm(500u + mode, layouts::kRgbcct);
    RenderParams pc = paramsFor(mode, {0, 0, 0, 200, 0});
    RenderParams pw = paramsFor(mode, {0, 0, 0, 0, 200});
    uint16_t dc[5], dw[5];
    uint32_t now = 0;
    bool same = true;
    for (int i = 0; i < 3000; ++i, now += kFrameMs) {
      if (i == 1000) {  // crossfade into the next mode and back, then sleep/wake
        pc.scene.mode = pw.scene.mode = static_cast<uint8_t>(mode % cfg::kNumModes + 1);
      }
      if (i == 1100) pc.scene.mode = pw.scene.mode = mode;
      if (i == 1800) pc.sleeping = pw.sleeping = 1;
      if (i == 2000) pc.sleeping = pw.sleeping = 0;
      if (i == 2400) pc.scene.brightness = pw.scene.brightness = 60;
      if (i == 2600) {  // white level change: smoothed alike
        pc.scene.color = {0, 0, 0, 40, 0};
        pw.scene.color = {0, 0, 0, 0, 40};
      }
      cool.frame(pc, now, dc);
      warm.frame(pw, now, dw);
      // Effect white lights both whites equally, so swapping the slots maps one run onto the other.
      same = same && dc[kR] == dw[kR] && dc[kG] == dw[kG] && dc[kB] == dw[kB] && dc[kCw] == dw[kWw] &&
             dc[kWw] == dw[kCw];
    }
    CHECK(same);
  }
}

TEST(rgbcct_effects_are_the_same_as_on_rgbw) {
  // Same seed and scene: the shared effects produce the same RGB + primary-white
  // light as on the RGBW fixture.
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    RenderEngine a(77u, layouts::kRgbw);
    RenderEngine b(77u, layouts::kRgbcct);
    RenderParams p = paramsFor(mode, {200, 60, 20, 90});
    uint16_t da[4], db[5];
    uint32_t now = 0;
    bool same = true;
    for (int i = 0; i < 1500; ++i, now += kFrameMs) {
      a.frame(p, now, da);
      b.frame(p, now, db);
      same = same && da[0] == db[kR] && da[1] == db[kG] && da[2] == db[kB] && da[3] == db[kCw];
    }
    CHECK(same);
  }
}

TEST(rgbcct_effect_white_lights_both_white_leds) {
  // Club auto palette white flashes and the fireworks burst flash use every
  // white LED: CW and WW together (neutral).
  for (uint8_t mode : std::initializer_list<uint8_t>{4, 9}) {
    RenderEngine engine(3u, layouts::kRgbcct);
    RenderParams p = paramsFor(mode, {0, 0, 0, 0, 0});  // black base: only effect light
    p.scene.clubColorMode = 1;
    p.scene.fireworkColorMode = 1;
    uint16_t duty[5];
    uint32_t now = 0;
    int whiteFrames = 0;
    bool balanced = true;
    for (int i = 0; i < 12000; ++i, now += kFrameMs) {
      engine.frame(p, now, duty);
      if (duty[kCw] > 0 || duty[kWw] > 0) {
        ++whiteFrames;
        balanced = balanced && duty[kCw] == duty[kWw];
      }
    }
    CHECK(whiteFrames > 0);
    CHECK(balanced);
  }
}
