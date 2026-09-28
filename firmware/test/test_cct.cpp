// The CCT fixture (fixtures/ElectroBright_CCT): the shared core with only cool
// white (CW) and warm white (WW) LEDs. Protocol widths, identity, defaults,
// persistence, and how coloured effect light becomes white temperature.

#include <math.h>
#include <string.h>

#include <algorithm>
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

const FixtureProfile& kCctFx = profiles::kCct;
constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;
constexpr int kCw = 0, kWw = 1;  // duty order = wire order
constexpr const char* kDefaultStatus = "STATUS:255,255,255,1,5,5,0,0,1,0,0,0,1,0,255,255,0";

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
  p.scene = state::defaultScene(kCctFx.defaults);
  p.scene.mode = mode;
  p.scene.color = color;
  p.fadeMs = cfg::kSleepFadeMs;
  return p;
}

}  // namespace

// ---- Identity and text protocol -------------------------------------------------------

TEST(cct_reports_its_identity_and_layout) {
  Rig r(kCctFx);
  r.send("INFO");
  r.send("VERSION");
  r.send("CAPS");
  CHECK_STR(r.env.lines[0], "INFO:EB-C3-CCT-V1");
  CHECK_STR(r.env.lines[1], std::string("VERSION:") + cfg::kFirmwareVersion);
  CHECK_STR(r.env.lines[2], "CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=CCT,OTA=0");
}

TEST(cct_status_has_17_fields_and_white_defaults) {
  Rig r(kCctFx);
  r.send("STATUS");
  CHECK_STR(r.env.last(), kDefaultStatus);
  CHECK_EQ(fieldCount(r.env.last()), size_t{17});
}

TEST(cct_color_takes_exactly_cool_and_warm) {
  Rig r(kCctFx);
  r.send("COLOR:40,200");
  CHECK(r.env.lines.empty());  // silent on success
  CHECK(r.core.scene().color == (Color8{0, 0, 0, 40, 200}));
  r.send("COLOR:1,2,3");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:1");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("COLOR:1,256");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("RGBW:1,2,3,4");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  r.send("STATUS");
  CHECK_EQ(r.env.last().rfind("STATUS:40,200,", 0), size_t{0});
}

TEST(cct_police_colours_take_two_values) {
  Rig r(kCctFx);
  r.send("POLICE_COLOR_A:10,20");
  CHECK_STR(r.env.last(), "OK");
  r.send("POLICE_COLOR_B:1,2,3");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  r.send("POLICE_COLOR_B:30,40");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  const std::string s = r.env.last();
  CHECK_STR(s.substr(s.size() - 12), ",10,20,30,40");
}

// ---- Binary frames --------------------------------------------------------------------

TEST(cct_binary_frame_is_six_bytes_with_its_own_salt) {
  uint8_t f[binframe::kMaxFrame];
  const size_t n = binframe::encode(3, layouts::kCct, {0, 0, 0, 40, 200}, 99, f);
  CHECK_EQ(n, size_t{6});
  CHECK_EQ(f[2], 40);
  CHECK_EQ(f[3], 200);
  CHECK_EQ(f[4], 99);
  CHECK_EQ(f[5], static_cast<uint8_t>(3 ^ 40 ^ 200 ^ 99 ^ 0x57));
  ColorFrame c{};
  CHECK(binframe::decode(f, n, layouts::kCct, false, c));
  CHECK(c.color == (Color8{0, 0, 0, 40, 200}) && c.brightness == 99 && c.seq == 3);
}

TEST(cct_applies_frames_and_rejects_other_fixtures_frames) {
  SimDevice d(kCctFx);
  connectAndSubscribe(d);
  uint8_t f[binframe::kMaxFrame];
  binframe::encode(0, layouts::kCct, {0, 0, 0, 10, 20}, 128, f);
  d.write(f, 6);
  d.pass();
  CHECK(d.core().scene().color == (Color8{0, 0, 0, 10, 20}));
  CHECK_EQ(d.core().scene().brightness, 128);

  // RGBW's legacy 6-byte frame has the same length but salt 0x55; the current
  // frames of RGBW, RGB and RGBCCT have other lengths. None may apply.
  const uint8_t legacy6[6] = {0xAA, 5, 6, 7, 8, static_cast<uint8_t>(5 ^ 6 ^ 7 ^ 8 ^ 0x55)};
  d.write(legacy6, 6);
  uint8_t other[binframe::kMaxFrame];
  for (const ChannelLayout* l : {&layouts::kRgbw, &layouts::kRgb, &layouts::kRgbcct}) {
    const size_t n = binframe::encode(1, *l, {9, 9, 9, 0}, 200, other);
    d.write(other, n);
  }
  d.pass();
  CHECK(d.core().scene().color == (Color8{0, 0, 0, 10, 20}));
  CHECK_EQ(Stats::get(d.stats().binaryBad), 4u);
  CHECK_STR(ask(d, "PING\n"), "OK\n");
  CHECK_EQ(Stats::get(d.stats().rxRejectedBytes), 0u);
}

// ---- Defaults and persistence -----------------------------------------------------------

TEST(cct_factory_reset_restores_white_defaults) {
  Rig r(kCctFx);
  r.send("COLOR:1,2");
  r.send("POLICE_COLOR_A:9,9");
  r.send("FACTORY_RESET");
  CHECK_STR(r.env.last(), "OK");
  r.send("STATUS");
  CHECK_STR(r.env.last(), kDefaultStatus);
}

TEST(cct_store_rejects_records_with_colour_values) {
  // A 47-byte RGBCCT record fits the size but carries RGB values: not a CCT scene.
  Scene s = state::defaultScene(kCctFx.defaults);
  s.color = {5, 0, 0, 10, 20};
  uint8_t rec[scenecodec::kMaxRecord];
  const size_t n = scenecodec::pack(s, layouts::kRgbcct, rec);
  CHECK_EQ(n, scenecodec::recordSize(layouts::kCct));
  Scene back{};
  CHECK(!scenecodec::unpack(rec, n, layouts::kCct, back));
  s.color = {0, 0, 0, 10, 20};
  scenecodec::pack(s, layouts::kRgbcct, rec);
  CHECK(scenecodec::unpack(rec, n, layouts::kCct, back));
}

TEST(cct_presets_and_scene_survive_a_power_cycle) {
  SimDevice d(kCctFx);
  connectAndSubscribe(d);
  ask(d, "COLOR:30,220\nMODE:13\n");
  CHECK_STR(ask(d, "PRESET_SAVE:4\n"), "OK\n");
  ask(d, "COLOR:9,9\nMODE:2\n");
  CHECK_STR(ask(d, "PRESET_LOAD:4\n"), "STATUS:30,220,255,13,5,5,0,0,1,0,0,0,1,0,255,255,0\n");
  ask(d, "COLOR:0,77\n");
  d.advance(cfg::kPersistMaxLatencyMs + 1000);
  CHECK_EQ(d.flash().data["scene"].size(), size_t{47});

  d.reboot();
  d.connect();
  d.setMtu(247);
  d.setSubscribed(true);
  d.pass();
  CHECK_STR(ask(d, "PRESET_LIST\n"), "PRESETS:4,\n");
  CHECK_EQ(ask(d, "STATUS\n").rfind("STATUS:0,77,", 0), size_t{0});
}

// ---- Colour -> white temperature ---------------------------------------------------------

TEST(cct_colour_maps_to_white_temperature) {
  auto map = [](LinColor c) { return chanmap::colourToWhites(c); };
  auto warmth = [&](LinColor c) {
    const LinColor o = map(c);
    return o.ww / (o.w + o.ww);
  };
  // Endpoints: red / orange warmest, cyan / blue coolest.
  CHECK(warmth({1, 0, 0, 0}) > 0.95);
  CHECK(warmth({1, 0.5f, 0, 0}) > 0.95);
  CHECK(warmth({0, 0.6f, 0.6f, 0}) < 0.05);
  CHECK(warmth({0, 0, 1, 0}) < 0.2);
  // Police red vs blue stay clearly apart.
  CHECK(warmth({1, 0, 0, 0}) - warmth({0, 0, 1, 0}) >= 0.8);
  // Cool + warm equals the colour's level: no doubled brightness at neutral colours.
  LinColor o = map({0.5f, 0.5f, 0.5f, 0});  // white: both, half each
  CHECK_NEAR(o.w, 0.25, 1e-6);
  CHECK_NEAR(o.ww, 0.25, 1e-6);
  o = map({0, 0.3f, 0, 0});  // green: its level, split
  CHECK_NEAR(o.w + o.ww, 0.3, 1e-6);
  o = map({0, 0, 0, 0.2f, 0.7f});  // white light passes through unchanged
  CHECK_NEAR(o.w, 0.2, 1e-6);
  CHECK_NEAR(o.ww, 0.7, 1e-6);
  CHECK_NEAR(o.r + o.g + o.b, 0.0, 1e-6);
  o = map({0, 0, 0, 0.9f, 0});
  CHECK_NEAR(o.w, 0.9, 1e-6);
  CHECK_NEAR(o.ww, 0.0, 1e-6);
  o = map({1, 0, 0, 0.5f, 0.8f});  // over full scale: scaled together, balance kept
  const float wr = chanmap::colourWarmth({1, 0, 0, 0});
  CHECK_NEAR(o.ww, 1.0, 1e-6);
  CHECK_NEAR(o.w, (0.5 + (1.0 - wr)) / (0.8 + wr), 1e-6);
}

TEST(cct_hue_sweep_is_continuous_with_steady_brightness) {
  // A full hue circle in 0.1 degree steps (the Rainbow sweep): warmth never
  // jumps, and cool + warm stays at the colour's level.
  float prev = -1.0f, first = -1.0f, maxStep = 0.0f, lo = 1.0f, hi = 0.0f;
  for (int i = 0; i <= 3600; ++i) {
    const float h = static_cast<float>(i % 3600) / 600.0f;  // sixths
    const float x = 1.0f - fabsf(fmodf(h, 2.0f) - 1.0f);
    LinColor c{};
    switch (static_cast<int>(h)) {
      case 0: c = {1, x, 0, 0}; break;
      case 1: c = {x, 1, 0, 0}; break;
      case 2: c = {0, 1, x, 0}; break;
      case 3: c = {0, x, 1, 0}; break;
      case 4: c = {x, 0, 1, 0}; break;
      default: c = {1, 0, x, 0}; break;
    }
    c = c * 0.8f;
    const LinColor o = chanmap::colourToWhites(c);
    CHECK_NEAR(o.w + o.ww, 0.8, 1e-5);
    const float w = o.ww / (o.w + o.ww);
    if (prev >= 0.0f) maxStep = std::max(maxStep, fabsf(w - prev));
    if (first < 0.0f) first = w;
    lo = std::min(lo, w);
    hi = std::max(hi, w);
    prev = w;
  }
  CHECK(maxStep < 0.001f);         // at most ~0.5 % per degree
  CHECK_NEAR(prev, first, 1e-6);   // closes the circle
  CHECK(hi - lo > 0.95f);          // still spans warm to cool
}

TEST(cct_every_mode_renders_two_bounded_channels_and_sleeps_dark) {
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    for (uint8_t cm = 0; cm <= 1; ++cm) {
      RenderEngine engine(0xCC7u + mode, layouts::kCct);
      RenderParams p = paramsFor(mode, kCctFx.defaults.color);
      p.scene.fireworkColorMode = p.scene.clubColorMode = p.scene.policeColorMode = cm;
      uint16_t duty[2];  // exactly two: ASan catches any third write
      uint32_t now = 0;
      uint32_t lit = 0;
      for (int i = 0; i < 2000; ++i, now += kFrameMs) {
        engine.frame(p, now, duty);
        CHECK(duty[kCw] <= cfg::kPwmMaxDuty && duty[kWw] <= cfg::kPwmMaxDuty);
        lit += (duty[kCw] | duty[kWw]) != 0;
      }
      CHECK(lit > 0);
      p.sleeping = 1;
      for (int i = 0; i < 200; ++i, now += kFrameMs) engine.frame(p, now, duty);
      CHECK_EQ(duty[kCw] + duty[kWw], 0);
    }
  }
}

TEST(cct_solid_whites_are_exact) {
  RenderEngine engine(1u, layouts::kCct);
  RenderParams p = paramsFor(1, {0, 0, 0, 255, 0});
  uint16_t duty[2];
  uint32_t now = 0;
  for (int i = 0; i < 400; ++i, now += kFrameMs) engine.frame(p, now, duty);
  CHECK_EQ(duty[kCw], cfg::kPwmMaxDuty);
  CHECK_EQ(duty[kWw], 0);
  p.scene.color = {0, 0, 0, 0, 255};
  for (int i = 0; i < 400; ++i, now += kFrameMs) engine.frame(p, now, duty);
  CHECK_EQ(duty[kCw], 0);
  CHECK_EQ(duty[kWw], cfg::kPwmMaxDuty);
}

TEST(cct_colour_modes_play_in_white_temperature) {
  // Rainbow sweeps warm -> neutral -> cool; auto police alternates warm (red)
  // and cool (blue); TV changes temperature. Each must show both warm-dominant
  // and cool-dominant moments.
  for (uint8_t mode : std::initializer_list<uint8_t>{5, 10, 12}) {
    RenderEngine engine(21u, layouts::kCct);
    RenderParams p = paramsFor(mode, kCctFx.defaults.color);
    p.scene.policeColorMode = 1;
    uint16_t duty[2];
    uint32_t now = 0;
    int warmOnly = 0, coolOnly = 0;
    for (int i = 0; i < 8000; ++i, now += kFrameMs) {
      engine.frame(p, now, duty);
      warmOnly += duty[kWw] > 2 * duty[kCw] + 100;
      coolOnly += duty[kCw] > 2 * duty[kWw] + 100;
    }
    CHECK(warmOnly > 0);
    CHECK(coolOnly > 0);
  }
}

TEST(cct_warm_and_cool_white_behave_identically_in_base_colour_modes) {
  // Modes that animate the user's colour: a pure warm-white scene drives the
  // WW LED exactly like a pure cool-white scene drives the CW LED.
  for (uint8_t mode : std::initializer_list<uint8_t>{1, 2, 3, 6, 7, 8, 11, 13}) {
    RenderEngine cool(900u + mode, layouts::kCct);
    RenderEngine warm(900u + mode, layouts::kCct);
    RenderParams pc = paramsFor(mode, {0, 0, 0, 200, 0});
    RenderParams pw = paramsFor(mode, {0, 0, 0, 0, 200});
    uint16_t dc[2], dw[2];
    uint32_t now = 0;
    bool same = true;
    for (int i = 0; i < 3000; ++i, now += kFrameMs) {
      if (i == 1800) pc.sleeping = pw.sleeping = 1;
      if (i == 2000) pc.sleeping = pw.sleeping = 0;
      if (i == 2400) {
        pc.scene.color = {0, 0, 0, 40, 0};
        pw.scene.color = {0, 0, 0, 0, 40};
      }
      cool.frame(pc, now, dc);
      warm.frame(pw, now, dw);
      same = same && dc[kCw] == dw[kWw] && dc[kWw] == dw[kCw];
    }
    CHECK(same);
  }
}

TEST(cct_white_modes_match_the_rgbcct_whites) {
  // With a white-only colour and no effect-made colour, the CCT light drives
  // its two LEDs exactly like the RGBCCT light drives its CW and WW LEDs.
  for (uint8_t mode : std::initializer_list<uint8_t>{1, 2, 3, 6, 7, 8, 11, 13}) {
    RenderEngine a(33u, layouts::kCct);
    RenderEngine b(33u, layouts::kRgbcct);
    RenderParams p = paramsFor(mode, {0, 0, 0, 120, 60});
    uint16_t da[2], db[5];
    uint32_t now = 0;
    bool same = true;
    for (int i = 0; i < 2000; ++i, now += kFrameMs) {
      a.frame(p, now, da);
      b.frame(p, now, db);
      same = same && da[kCw] == db[3] && da[kWw] == db[4] && db[0] == 0 && db[1] == 0 && db[2] == 0;
    }
    CHECK(same);
  }
}
