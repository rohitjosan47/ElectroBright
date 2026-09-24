// The RGB fixture (fixtures/ElectroBright_RGB): the shared core with a
// three-channel layout. Protocol widths, identity, defaults, persistence and
// rendering specific to a light without a white channel.

#include <string.h>

#include <string>
#include <vector>

#include "Fakes.h"
#include "Fixtures.h"
#include "TestFramework.h"
#include "fwsim/SimDevice.h"
#include "protocol/BinaryFrame.h"
#include "render/ChannelMap.h"
#include "render/RenderEngine.h"
#include "state/SceneCodec.h"

namespace {

const FixtureProfile& kRgb = fx::rgb::kProfile;
constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;

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

}  // namespace

// ---- Identity ---------------------------------------------------------------------

TEST(rgb_reports_its_identity_and_layout) {
  Rig r(kRgb);
  r.send("INFO");
  r.send("VERSION");
  r.send("CAPS");
  CHECK_STR(r.env.lines[0], "INFO:EB-C3-RGB-V1");
  CHECK_STR(r.env.lines[1], std::string("VERSION:") + cfg::kFirmwareVersion);
  CHECK_STR(r.env.lines[2], "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,LAYOUT=RGB");
}

// ---- Text protocol ------------------------------------------------------------------

TEST(rgb_status_has_twenty_fields_with_rgb_colours) {
  Rig r(kRgb);
  r.send("STATUS");
  CHECK_STR(r.env.last(), "STATUS:255,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,255,255,255");
  CHECK_EQ(fieldCount(r.env.last()), size_t{20});
}

TEST(rgb_color_takes_exactly_three_values) {
  Rig r(kRgb);
  r.send("COLOR:10,20,30");
  CHECK(r.env.lines.empty());  // silent on success, like RGBW's colour command
  CHECK_EQ(r.core.scene().color.r, 10);
  CHECK_EQ(r.core.scene().color.g, 20);
  CHECK_EQ(r.core.scene().color.b, 30);
  CHECK_EQ(r.core.scene().color.w, 0);

  r.send("COLOR:1,2,3,4");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:1,2");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:1,2,256");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:7,8,9,");  // a single trailing comma is tolerated
  CHECK_EQ(r.core.scene().color.b, 9);
  r.send("STATUS");
  CHECK_EQ(r.env.last().rfind("STATUS:7,8,9,", 0), size_t{0});
}

TEST(rgb_has_no_rgbw_command) {
  Rig r(kRgb);
  r.send("RGBW:1,2,3,4");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  r.send("RGBW:1,2,3");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  CHECK_EQ(r.core.scene().color.r, 255);  // unchanged
}

TEST(rgb_police_colours_take_three_values) {
  Rig r(kRgb);
  r.send("POLICE_COLOR_A:1,2,3");
  CHECK_STR(r.env.last(), "OK");
  r.send("POLICE_COLOR_B:4,5,6,7");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("POLICE_COLOR_B:40,50,60");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  const std::string s = r.env.last();
  CHECK_STR(s.substr(s.size() - 15), ",1,2,3,40,50,60");
  CHECK_EQ(r.core.scene().policeB.w, 0);
}

TEST(rgb_colour_commands_coalesce_like_rgbw) {
  Rig r(kRgb);
  const char* lines[] = {"COLOR:1,1,1", "COLOR:2,2,2", "COLOR:3,3,3"};
  r.core.processLines(lines, 3, r.now);
  CHECK_EQ(r.core.scene().color.r, 3);
  CHECK_EQ(Stats::get(r.stats.coalesced), 2u);
}

// ---- Binary frames --------------------------------------------------------------------

TEST(rgb_binary_frame_is_seven_bytes_with_its_own_salt) {
  uint8_t f[binframe::kMaxFrame];
  const size_t n = binframe::encode(5, layouts::kRgb, {10, 20, 30, 0}, 99, f);
  CHECK_EQ(n, size_t{7});
  CHECK_EQ(f[0], 0xAA);
  CHECK_EQ(f[1], 5);
  CHECK_EQ(f[2], 10);
  CHECK_EQ(f[4], 30);
  CHECK_EQ(f[5], 99);
  CHECK_EQ(f[6], static_cast<uint8_t>(5 ^ 10 ^ 20 ^ 30 ^ 99 ^ 0x56));
  ColorFrame c{};
  CHECK(binframe::decode(f, n, layouts::kRgb, false, c));
  CHECK(c.hasSeq && c.seq == 5 && c.hasBrightness && c.brightness == 99);
  CHECK(c.color == (Color8{10, 20, 30, 0}));
}

TEST(rgb_applies_frames_and_rejects_rgbw_ones) {
  SimDevice d(kRgb);
  connectAndSubscribe(d);

  uint8_t f[binframe::kMaxFrame];
  binframe::encode(0, layouts::kRgb, {10, 20, 30, 0}, 128, f);
  d.write(f, 7);
  d.pass();
  CHECK(d.core().scene().color == (Color8{10, 20, 30, 0}));
  CHECK_EQ(d.core().scene().brightness, 128);

  // An RGBW app's frames: current 8-byte, legacy 7-byte (same length as an RGB
  // frame but salted 0x55) and legacy 6-byte. All counted bad, none applied.
  uint8_t rgbw[8];
  binframe::encode8(1, {1, 2, 3, 4}, 200, rgbw);
  d.write(rgbw, 8);
  const uint8_t legacy7[7] = {0xAA, 11, 22, 33, 44, 55, static_cast<uint8_t>(11 ^ 22 ^ 33 ^ 44 ^ 55 ^ 0x55)};
  d.write(legacy7, 7);
  const uint8_t legacy6[6] = {0xAA, 5, 6, 7, 8, static_cast<uint8_t>(5 ^ 6 ^ 7 ^ 8 ^ 0x55)};
  d.write(legacy6, 6);
  d.pass();
  CHECK(d.core().scene().color == (Color8{10, 20, 30, 0}));
  CHECK_EQ(Stats::get(d.stats().binaryBad), 3u);
  CHECK_EQ(Stats::get(d.stats().binaryOk), 1u);
  // ...and they never reached the text parser: the next command works.
  CHECK_STR(ask(d, "PING\n"), "OK\n");
  CHECK_EQ(Stats::get(d.stats().rxRejectedBytes), 0u);
}

TEST(rgb_frames_never_wake_a_sleeping_light) {
  SimDevice d(kRgb);
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "SLEEP\n"), "OK\n");
  uint8_t f[binframe::kMaxFrame];
  binframe::encode(0, layouts::kRgb, {1, 2, 3, 0}, 50, f);
  d.write(f, 7);
  d.pass();
  CHECK(d.core().sleeping());
  CHECK_EQ(d.core().scene().color.b, 3);  // stored for the next wake
}

// ---- Defaults, persistence ------------------------------------------------------------

TEST(rgb_factory_reset_restores_rgb_defaults) {
  Rig r(kRgb);
  r.send("COLOR:1,2,3");
  r.send("POLICE_COLOR_B:9,9,9");
  r.send("FACTORY_RESET");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  CHECK_STR(r.env.last(), "STATUS:255,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,255,255,255");
}

TEST(rgb_store_rejects_records_with_a_white_value) {
  // A record whose colours use W cannot come from an RGB fixture (e.g. flash
  // written by other firmware): it is treated as absent.
  MockKv kv;
  Stats st;
  Scene bad = state::defaultScene(kRgb.defaults);
  bad.color = {1, 2, 3, 4};
  // Same record size as RGB (neither has warm white); written with W kept.
  std::vector<uint8_t> rec(scenecodec::recordSize(layouts::kRgbw));
  scenecodec::pack(bad, layouts::kRgbw, rec.data());
  kv.data["scene"] = rec;
  kv.data["p02"] = rec;
  StateStore store(kv, st, kRgb);
  Scene s;
  Settings set;
  store.load(s, set);
  CHECK(s.color == kRgb.defaults.color);
  CHECK_EQ(store.presetMask(), 0u);
  CHECK(!store.savePreset(0, bad));  // never writes one either
}

TEST(rgb_presets_and_scene_survive_a_power_cycle) {
  SimDevice d(kRgb);
  connectAndSubscribe(d);
  ask(d, "COLOR:10,20,30\nMODE:6\nMODE_SPEED:6,3\n");
  CHECK_STR(ask(d, "PRESET_SAVE:3\n"), "OK\n");
  ask(d, "COLOR:1,1,1\nMODE:2\n");
  CHECK_STR(ask(d, "PRESET_LOAD:3\n"), "STATUS:10,20,30,255,6,3,5,0,0,1,0,0,0,1,255,165,0,255,255,255\n");
  ask(d, "COLOR:40,50,60\n");
  d.advance(cfg::kPersistMaxLatencyMs + 1000);
  CHECK(d.flash().data.count("scene") == 1);
  CHECK(d.flash().data.count("p03") == 1);

  d.reboot();
  d.connect();
  d.setMtu(247);
  d.setSubscribed(true);
  d.pass();
  CHECK_STR(ask(d, "PRESET_LIST\n"), "PRESETS:3,\n");
  CHECK_EQ(ask(d, "STATUS\n").rfind("STATUS:40,50,60,", 0), size_t{0});
}

TEST(rgb_status_is_chunked_to_the_mtu) {
  SimDevice d(kRgb);
  d.boot();
  d.connect();  // MTU 23 -> 20-byte notifications
  d.setSubscribed(true);
  d.pass();
  writeText(d, "STATUS\n");
  d.pass();
  const auto chunks = d.takeNotifications();
  std::string all;
  for (const auto& c : chunks) {
    CHECK(c.size() <= 20);
    all.append(c.begin(), c.end());
  }
  CHECK(chunks.size() >= 3);
  CHECK_EQ(fieldCount(all.substr(0, all.size() - 1)), size_t{20});
}

// ---- Rendering --------------------------------------------------------------------------

TEST(rgb_fold_turns_white_light_into_neutral_rgb) {
  const LinColor mix = kRgb.whiteMix;
  const LinColor w = chanmap::foldWhite({0, 0, 0, 1}, mix);
  CHECK_NEAR(w.r, 1.0, 1e-6);
  CHECK_NEAR(w.g, 1.0, 1e-6);
  CHECK_NEAR(w.b, 1.0, 1e-6);
  CHECK_NEAR(w.w, 0.0, 1e-6);
  // No white: untouched.
  const LinColor c = chanmap::foldWhite({0.2f, 0.4f, 0.6f, 0}, mix);
  CHECK_NEAR(c.r, 0.2, 1e-6);
  CHECK_NEAR(c.b, 0.6, 1e-6);
  // Over full scale: scaled down together, so the hue (channel ratios) is kept.
  const LinColor s = chanmap::foldWhite({1.0f, 0.9f, 0.85f, 1.0f}, mix);  // the club white strobe
  CHECK_NEAR(s.r, 1.0, 1e-6);
  CHECK_NEAR(s.g, 1.9 / 2.0, 1e-6);
  CHECK_NEAR(s.b, 1.85 / 2.0, 1e-6);
}

TEST(rgb_every_mode_renders_three_bounded_channels_and_sleeps_dark) {
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    for (uint8_t cm = 0; cm <= 1; ++cm) {
      RenderEngine engine(0xBEEFu + mode, layouts::kRgb, kRgb.whiteMix);
      RenderParams p{};
      p.scene = state::defaultScene(kRgb.defaults);
      p.scene.mode = mode;
      p.scene.fireworkColorMode = p.scene.clubColorMode = p.scene.policeColorMode = cm;
      p.fadeMs = cfg::kSleepFadeMs;
      uint16_t duty[3];  // exactly three: ASan catches any fourth write
      uint32_t now = 0;
      uint32_t lit = 0;
      for (int i = 0; i < 2000; ++i, now += kFrameMs) {
        engine.frame(p, now, duty);
        for (uint16_t d : duty) CHECK(d <= cfg::kPwmMaxDuty);
        lit += (duty[0] | duty[1] | duty[2]) != 0;
      }
      CHECK(lit > 0);
      p.sleeping = 1;
      for (int i = 0; i < 200; ++i, now += kFrameMs) engine.frame(p, now, duty);
      CHECK_EQ(duty[0] + duty[1] + duty[2], 0);
    }
  }
}

TEST(rgb_effects_are_the_same_as_on_rgbw) {
  // Same seed, same scene: the effect pipeline produces the same light on both
  // fixtures; only the final channel mapping differs.
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    RenderEngine a(77u, layouts::kRgbw);
    RenderEngine b(77u, layouts::kRgb, kRgb.whiteMix);
    RenderParams p{};
    p.scene = state::defaultScene(kRgb.defaults);
    p.scene.mode = mode;
    p.scene.color = {200, 60, 20, 0};
    p.fadeMs = cfg::kSleepFadeMs;
    uint16_t da[4], db[3];
    uint32_t now = 0;
    bool same = true;
    for (int i = 0; i < 1500; ++i, now += kFrameMs) {
      a.frame(p, now, da);
      b.frame(p, now, db);
      const LinColor oa = a.lastOutput(), ob = b.lastOutput();
      same = same && oa.r == ob.r && oa.g == ob.g && oa.b == ob.b && oa.w == ob.w;
      // Without white light the duties are identical too.
      if (oa.w == 0.0f) same = same && da[0] == db[0] && da[1] == db[1] && da[2] == db[2];
    }
    CHECK(same);
  }
}

TEST(rgb_club_white_strobe_uses_all_three_leds) {
  // Club auto palette includes white flashes (W on RGBW). On RGB they must be
  // near-neutral light from all three LEDs, never a dark or tinted gap.
  RenderEngine engine(3u, layouts::kRgb, kRgb.whiteMix);
  RenderParams p{};
  p.scene = state::defaultScene(kRgb.defaults);
  p.scene.mode = 9;
  p.scene.clubColorMode = 1;
  p.fadeMs = cfg::kSleepFadeMs;
  uint16_t duty[3];
  uint32_t now = 0;
  int whiteFrames = 0;
  for (int i = 0; i < 12000; ++i, now += kFrameMs) {
    engine.frame(p, now, duty);
    const LinColor o = engine.lastOutput();
    if (o.w > 0.5f && o.r > 0.5f) {
      ++whiteFrames;
      CHECK(duty[0] > 0 && duty[1] > 0 && duty[2] > 0);
      CHECK(duty[2] * 10 >= duty[0] * 8);  // blue within 20 % of red: neutral
    }
  }
  CHECK(whiteFrames > 0);
}
