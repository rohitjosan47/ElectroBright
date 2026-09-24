// The single-white fixture (fixtures/ElectroBright_W): the shared core with one
// white LED. Protocol widths, the removed Rainbow mode, identity, defaults,
// persistence, and coloured effect light shown as brightness.

#include <math.h>
#include <string.h>

#include <initializer_list>
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

const FixtureProfile& kWFx = fx::w::kProfile;
constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;
constexpr const char* kDefaultStatus = "STATUS:255,255,1,5,5,0,0,1,0,0,0,1,255,255";

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

RenderParams paramsFor(uint8_t mode, uint8_t white = 255) {
  RenderParams p{};
  p.scene = state::defaultScene(kWFx.defaults);
  p.scene.mode = mode;
  p.scene.color = {0, 0, 0, white};
  p.fadeMs = cfg::kSleepFadeMs;
  return p;
}

// Coefficient of variation of the output after the boot fade.
double levelVariation(uint8_t mode, uint8_t colorMode) {
  RenderEngine e(7u, layouts::kW);
  RenderParams p = paramsFor(mode);
  p.scene.fireworkColorMode = p.scene.clubColorMode = p.scene.policeColorMode = colorMode;
  uint16_t d[1];
  double sum = 0, sq = 0;
  int n = 0;
  uint32_t now = 0;
  for (int i = 0; i < 6000; ++i, now += kFrameMs) {
    e.frame(p, now, d);
    if (i < 400) continue;
    sum += d[0];
    sq += double(d[0]) * d[0];
    ++n;
  }
  const double mean = sum / n;
  return mean > 0 ? sqrt(fmax(0.0, sq / n - mean * mean)) / mean : 0.0;
}

}  // namespace

// ---- Identity and text protocol -------------------------------------------------------

TEST(w_reports_its_identity_layout_and_modes) {
  Rig r(kWFx);
  r.send("INFO");
  r.send("VERSION");
  r.send("CAPS");
  CHECK_STR(r.env.lines[0], "INFO:EB-C3-W-V1");
  CHECK_STR(r.env.lines[1], std::string("VERSION:") + cfg::kFirmwareVersion);
  CHECK_STR(r.env.lines[2], "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,LAYOUT=W,MODES=1DFF");
}

TEST(w_status_has_14_fields_and_full_white_default) {
  Rig r(kWFx);
  r.send("STATUS");
  CHECK_STR(r.env.last(), kDefaultStatus);
  CHECK_EQ(fieldCount(r.env.last()), size_t{14});
}

TEST(w_color_takes_one_value) {
  Rig r(kWFx);
  r.send("COLOR:80");
  CHECK(r.env.lines.empty());
  CHECK(r.core.scene().color == (Color8{0, 0, 0, 80}));
  r.send("COLOR:1,2");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:256");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("RGBW:1,2,3,4");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  r.send("POLICE_COLOR_A:40");
  CHECK_STR(r.env.last(), "OK");
  r.send("POLICE_COLOR_B:1,2");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("STATUS");
  CHECK_STR(r.env.last(), "STATUS:80,255,1,5,5,0,0,1,0,0,0,1,40,255");
}

TEST(w_rainbow_is_not_available) {
  Rig r(kWFx);
  r.send("MODE:10");
  CHECK_STR(r.env.last(), "ERROR:MODE_INVALID");
  r.send("MODE_SPEED:10,3");
  CHECK_STR(r.env.last(), "ERROR:MODE_SPEED_INVALID");
  r.send("MODE_FREQUENCY:10,3");
  CHECK_STR(r.env.last(), "ERROR:MODE_FREQUENCY_INVALID");
  r.send("MODE_CAPABILITIES:10");
  CHECK_STR(r.env.last(), "ERROR:MODE_INVALID");
  CHECK_EQ(r.core.scene().mode, 1);
  for (int m = 1; m <= cfg::kNumModes; ++m) {
    if (m == kModeRainbow) continue;
    r.send(("MODE:" + std::to_string(m)).c_str());
    CHECK_STR(r.env.last(), "OK");
    CHECK_EQ(r.core.scene().mode, m);
  }
}

TEST(w_rejects_stored_scenes_in_rainbow_mode) {
  // e.g. flash from another fixture's firmware: treated as absent.
  Scene s = state::defaultScene(kWFx.defaults);
  s.mode = kModeRainbow;
  uint8_t rec[scenecodec::kMaxRecord];
  const size_t n = scenecodec::pack(s, layouts::kW, rec);
  CHECK_EQ(n, size_t{44});
  MockKv kv;
  Stats st;
  kv.data["scene"] = std::vector<uint8_t>(rec, rec + n);
  kv.data["p05"] = std::vector<uint8_t>(rec, rec + n);
  StateStore store(kv, st, kWFx);
  Scene loaded;
  Settings set;
  store.load(loaded, set);
  CHECK_EQ(loaded.mode, 1);
  CHECK_EQ(store.presetMask(), 0u);
}

// ---- Binary frames --------------------------------------------------------------------

TEST(w_binary_frame_is_five_bytes_with_its_own_salt) {
  uint8_t f[binframe::kMaxFrame];
  const size_t n = binframe::encode(4, layouts::kW, {0, 0, 0, 90}, 200, f);
  CHECK_EQ(n, size_t{5});
  CHECK_EQ(f[2], 90);
  CHECK_EQ(f[3], 200);
  CHECK_EQ(f[4], static_cast<uint8_t>(4 ^ 90 ^ 200 ^ 0x54));
  ColorFrame c{};
  CHECK(binframe::decode(f, n, layouts::kW, false, c));
  CHECK(c.color == (Color8{0, 0, 0, 90}) && c.brightness == 200 && c.seq == 4);
}

TEST(w_applies_frames_and_rejects_other_fixtures_frames) {
  SimDevice d(kWFx);
  connectAndSubscribe(d);
  uint8_t f[binframe::kMaxFrame];
  binframe::encode(0, layouts::kW, {0, 0, 0, 33}, 128, f);
  d.write(f, 5);
  d.pass();
  CHECK(d.core().scene().color == (Color8{0, 0, 0, 33}));
  CHECK_EQ(d.core().scene().brightness, 128);

  uint8_t other[binframe::kMaxFrame];
  int sent = 0;
  for (const ChannelLayout* l : {&layouts::kRgbw, &layouts::kRgb, &layouts::kRgbcct, &layouts::kCct}) {
    d.write(other, binframe::encode(1, *l, {9, 9, 9, 9, 9}, 200, other));
    ++sent;
  }
  const uint8_t legacy6[6] = {0xAA, 5, 6, 7, 8, static_cast<uint8_t>(5 ^ 6 ^ 7 ^ 8 ^ 0x55)};
  d.write(legacy6, 6);
  ++sent;
  d.pass();
  CHECK(d.core().scene().color == (Color8{0, 0, 0, 33}));
  CHECK_EQ(Stats::get(d.stats().binaryBad), static_cast<uint32_t>(sent));
  CHECK_STR(ask(d, "PING\n"), "OK\n");
  CHECK_EQ(Stats::get(d.stats().rxRejectedBytes), 0u);
}

// ---- Defaults and persistence -----------------------------------------------------------

TEST(w_factory_reset_restores_full_white) {
  Rig r(kWFx);
  r.send("COLOR:9");
  r.send("MODE:6");
  r.send("FACTORY_RESET");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  CHECK_STR(r.env.last(), kDefaultStatus);
}

TEST(w_presets_and_scene_survive_a_power_cycle) {
  SimDevice d(kWFx);
  connectAndSubscribe(d);
  ask(d, "COLOR:120\nMODE:6\n");
  CHECK_STR(ask(d, "PRESET_SAVE:2\n"), "OK\n");
  ask(d, "COLOR:5\nMODE:2\n");
  CHECK_STR(ask(d, "PRESET_LOAD:2\n"), "STATUS:120,255,6,5,5,0,0,1,0,0,0,1,255,255\n");
  ask(d, "COLOR:66\n");
  d.advance(cfg::kPersistMaxLatencyMs + 1000);
  CHECK_EQ(d.flash().data["scene"].size(), size_t{44});

  d.reboot();
  d.connect();
  d.setMtu(247);
  d.setSubscribed(true);
  d.pass();
  CHECK_STR(ask(d, "PRESET_LIST\n"), "PRESETS:2,\n");
  CHECK_EQ(ask(d, "STATUS\n").rfind("STATUS:66,", 0), size_t{0});
}

// ---- Rendering ----------------------------------------------------------------------------

TEST(w_colour_becomes_brightness) {
  LinColor o = chanmap::colourToWhite({1, 0, 0, 0});  // red flash: full
  CHECK_NEAR(o.w, 1.0, 1e-6);
  o = chanmap::colourToWhite({0, 0, 0.4f, 0});  // blue: its level
  CHECK_NEAR(o.w, 0.4, 1e-6);
  o = chanmap::colourToWhite({0.2f, 0.5f, 0.1f, 0.3f});  // white light adds, strongest channel counts
  CHECK_NEAR(o.w, 0.8, 1e-6);
  o = chanmap::colourToWhite({1, 1, 1, 1, 1});  // effect white: capped at full
  CHECK_NEAR(o.w, 1.0, 1e-6);
  CHECK_NEAR(o.r + o.g + o.b + o.ww, 0.0, 1e-6);
}

TEST(w_rainbow_would_be_flat_every_kept_mode_varies) {
  // Why Rainbow is removed, measured: on a single white LED it is a constant
  // level. Every other animated mode visibly varies its intensity.
  CHECK(levelVariation(kModeRainbow, 0) < 0.001);
  for (uint8_t mode = 2; mode <= cfg::kNumModes; ++mode) {
    if (mode == kModeRainbow) continue;
    for (uint8_t cm = 0; cm <= 1; ++cm) CHECK(levelVariation(mode, cm) > 0.05);
  }
}

TEST(w_every_mode_renders_one_bounded_channel_and_sleeps_dark) {
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    if (!layout::supportsMode(layouts::kW, mode)) continue;
    for (uint8_t cm = 0; cm <= 1; ++cm) {
      RenderEngine engine(0x3u + mode, layouts::kW);
      RenderParams p = paramsFor(mode);
      p.scene.fireworkColorMode = p.scene.clubColorMode = p.scene.policeColorMode = cm;
      uint16_t duty[1];  // exactly one: ASan catches any second write
      uint32_t now = 0;
      uint32_t lit = 0;
      for (int i = 0; i < 2000; ++i, now += kFrameMs) {
        engine.frame(p, now, duty);
        CHECK(duty[0] <= cfg::kPwmMaxDuty);
        lit += duty[0] != 0;
      }
      CHECK(lit > 0);
      p.sleeping = 1;
      for (int i = 0; i < 200; ++i, now += kFrameMs) engine.frame(p, now, duty);
      CHECK_EQ(duty[0], 0);
    }
  }
}

TEST(w_white_modes_match_the_rgbw_white_led) {
  // With a white-only colour, modes that animate the user's colour drive the
  // single LED exactly like the RGBW light drives its W LED.
  for (uint8_t mode : std::initializer_list<uint8_t>{1, 2, 3, 6, 7, 8, 11, 13}) {
    RenderEngine a(44u, layouts::kW);
    RenderEngine b(44u, layouts::kRgbw);
    RenderParams p = paramsFor(mode, 150);
    uint16_t da[1], db[4];
    uint32_t now = 0;
    bool same = true;
    for (int i = 0; i < 2000; ++i, now += kFrameMs) {
      a.frame(p, now, da);
      b.frame(p, now, db);
      same = same && da[0] == db[3] && db[0] == 0 && db[1] == 0 && db[2] == 0;
    }
    CHECK(same);
  }
}
