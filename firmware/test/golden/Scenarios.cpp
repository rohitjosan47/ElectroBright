// Golden baseline of firmware behaviour (render output + protocol transcripts).
//
// `golden_rgbw_matches_baseline` replays a fixed set of scenarios and compares
// the result with golden/rgbw.golden, recorded from firmware v3.4.0 before the
// firmware-family refactor (tag fw-3.4.0-golden). Intended changes since then:
//   3.5.0  VERSION, and CAPS gained LAYOUT=RGBW
//   3.5.0  5- and 9-byte 0xAA writes (single-white / RGBCCT frames) count as
//          bad binary frames (DIAG binbad) instead of going to the text parser,
//          so the STATUS after them is answered instead of swallowed
//   3.6.0  VERSION; kNumPresets 25 → 15, CAPS gained PRESETS=15, legacy
//          presets wiped once on first boot (marker key pv): PRESET_*:15 is
//          out of range, and DIAG nvsw counts the marker write
// Any other difference means RGBW behaviour changed.
//
//   make golden-record     rewrite the golden file (only when a change is intended)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <functional>
#include <initializer_list>
#include <string>
#include <vector>

#include "../TestFramework.h"
#include "GoldenAdapter.h"

namespace {

constexpr const char* kGoldenPath = "golden/rgbw.golden";
constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;

// ---- Render streams -------------------------------------------------------------

struct Fnv {
  uint64_t h = 1469598103934665603ull;
  void add(uint16_t v) {
    for (int i = 0; i < 2; ++i) {
      h ^= static_cast<uint8_t>(v >> (8 * i));
      h *= 1099511628211ull;
    }
  }
};

struct Stream {
  golden::Engine engine;
  RenderParams p{};
  uint32_t now;
  uint16_t duty[golden::kChannels] = {};
  Fnv fnv;
  uint32_t frames = 0;

  explicit Stream(uint32_t seed, uint32_t start = 0) : engine(seed), now(start) {
    p.scene = golden::defaultScene();
    p.sleeping = 0;
    p.fadeMs = cfg::kSleepFadeMs;
  }
  void step(uint32_t dt = kFrameMs) {
    engine.frame(p, now, duty);
    for (int i = 0; i < golden::kChannels; ++i) fnv.add(duty[i]);
    ++frames;
    now += dt;
  }
  void run(uint32_t ms) {
    for (uint32_t t = 0; t < ms; t += kFrameMs) step();
  }
};

struct Lcg {
  uint32_t s;
  uint32_t next() { return s = s * 1664525u + 1013904223u; }
  uint8_t byte() { return static_cast<uint8_t>(next() >> 24); }
};

void setLevels(Scene& s, uint8_t speed, uint8_t freq) {
  for (auto& v : s.speed) v = speed;
  for (auto& v : s.freq) v = freq;
}

std::string streamLine(const char* name, const Stream& s) {
  char buf[160];
  snprintf(buf, sizeof(buf), "stream %s frames=%u fnv=%016llx\n", name, s.frames,
           static_cast<unsigned long long>(s.fnv.h));
  return buf;
}

std::string renderStreams() {
  std::string out;
  char name[64];

  // Every mode x 3 seeds / slider settings / colours (one with a non-zero W).
  struct Variant { uint32_t seed; uint8_t speed, freq; Color8 color; uint8_t bright; };
  const Variant variants[] = {
      {1u, 5, 5, {255, 0, 0, 0}, 255},
      {2u, 1, 10, {10, 200, 90, 0}, 128},
      {0xC0FFEEu, 10, 1, {255, 180, 60, 120}, 200},
  };
  for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
    for (size_t v = 0; v < 3; ++v) {
      Stream s(variants[v].seed);
      s.p.scene.mode = mode;
      s.p.scene.color = variants[v].color;
      s.p.scene.brightness = variants[v].bright;
      setLevels(s.p.scene, variants[v].speed, variants[v].freq);
      s.run(20000);
      snprintf(name, sizeof(name), "mode%u_v%zu", mode, v);
      out += streamLine(name, s);
    }
  }

  // Colour-source modes (fireworks, club, police) in both settings, custom police colours.
  for (const uint8_t mode : std::initializer_list<uint8_t>{4, 9, 12}) {
    for (uint8_t cm = 0; cm <= 1; ++cm) {
      Stream s(7u + mode);
      s.p.scene.mode = mode;
      s.p.scene.color = {40, 90, 250, 30};
      s.p.scene.fireworkColorMode = cm;
      s.p.scene.clubColorMode = cm;
      s.p.scene.policeColorMode = cm;
      s.p.scene.policeA = {200, 20, 0, 60};
      s.p.scene.policeB = {0, 30, 255, 200};
      s.run(10000);
      snprintf(name, sizeof(name), "colormode_m%u_cm%u", mode, cm);
      out += streamLine(name, s);
    }
  }

  {  // Mode switches every 150 ms (inside the 300 ms crossfade).
    Stream s(11u);
    s.run(1000);
    for (int i = 0; i < 40; ++i) {
      s.p.scene.mode = static_cast<uint8_t>(1 + (i * 5) % cfg::kNumModes);
      s.run(150);
    }
    out += streamLine("crossfade_chain", s);
  }

  {  // Sleep / wake / timer fades, including interrupted fades.
    Stream s(12u);
    s.p.scene.mode = 3;
    s.run(2000);
    s.p.sleeping = 1;
    s.p.fadeMs = cfg::kSleepFadeMs;
    s.run(1000);
    s.p.sleeping = 0;
    s.run(200);  // wake mid-way
    s.p.sleeping = 1;
    s.run(100);  // sleep again during the wake fade
    s.p.sleeping = 0;
    s.run(1500);
    s.p.sleeping = 1;
    s.p.fadeMs = cfg::kTimerSleepFadeMs;
    s.run(3000);
    s.p.sleeping = 0;
    s.p.fadeMs = cfg::kSleepFadeMs;
    s.run(1000);
    out += streamLine("sleep_wake_timer", s);
  }

  // Colour and brightness streaming (smoothing) in solid and breath.
  for (const uint8_t mode : std::initializer_list<uint8_t>{1, 3, 6}) {
    Stream s(13u);
    Lcg r{mode};
    s.p.scene.mode = mode;
    for (int i = 0; i < 150; ++i) {
      s.p.scene.color = {r.byte(), r.byte(), r.byte(), static_cast<uint8_t>(i % 3 == 0 ? r.byte() : 0)};
      s.p.scene.brightness = r.byte();
      s.run(35);
    }
    s.run(1000);
    snprintf(name, sizeof(name), "color_stream_m%u", mode);
    out += streamLine(name, s);
  }

  // Slider changes while effects run.
  for (const uint8_t mode : std::initializer_list<uint8_t>{2, 4, 6, 8, 9, 11}) {
    Stream s(14u);
    Lcg r{mode * 7u};
    s.p.scene.mode = mode;
    s.p.scene.color = {255, 120, 40, 0};
    for (int i = 0; i < 24; ++i) {
      s.p.scene.speed[mode - 1] = static_cast<uint8_t>(1 + r.next() % 10);
      s.p.scene.freq[mode - 1] = static_cast<uint8_t>(1 + r.next() % 10);
      s.run(500);
    }
    snprintf(name, sizeof(name), "sliders_m%u", mode);
    out += streamLine(name, s);
  }

  // Uneven frame times (scheduler jitter, stalls longer than the 50 ms clamp).
  for (const uint8_t mode : std::initializer_list<uint8_t>{3, 6, 8, 11, 13}) {
    Stream s(15u);
    s.p.scene.mode = mode;
    const uint32_t dts[] = {1, 5, 9, 17, 3, 60, 5, 0, 120, 5};
    for (int i = 0; i < 2000; ++i) s.step(dts[i % 10]);
    snprintf(name, sizeof(name), "jitter_m%u", mode);
    out += streamLine(name, s);
  }

  // millis() wrap-around.
  for (const uint8_t mode : std::initializer_list<uint8_t>{3, 7, 10}) {
    Stream s(16u, 0xFFFFFFFFu - 3000u);
    s.p.scene.mode = mode;
    s.run(6000);
    snprintf(name, sizeof(name), "wrap_m%u", mode);
    out += streamLine(name, s);
  }
  return out;
}

// ---- Protocol transcripts (fwsim: real controller + platform glue) ----------------

std::string escape(const std::vector<uint8_t>& bytes) {
  std::string s;
  for (uint8_t b : bytes) {
    if (b >= 0x20 && b < 0x7F && b != '\\') {
      s += static_cast<char>(b);
    } else {
      char e[8];
      snprintf(e, sizeof(e), "\\x%02X", b);
      s += e;
    }
  }
  return s;
}

std::string hex(const uint8_t* p, size_t n) {
  std::string s;
  char b[4];
  for (size_t i = 0; i < n; ++i) {
    snprintf(b, sizeof(b), "%02X", p[i]);
    s += b;
  }
  return s;
}

struct Transcript {
  std::unique_ptr<SimDevice> dev = golden::makeDevice();
  std::string out;
  uint8_t seq = 0;

  explicit Transcript(const char* name) {
    out += "transcript ";
    out += name;
    out += "\n";
    dev->boot();
    drain();
    open();
  }
  void open() {
    dev->connect();
    dev->setSubscribed(true);
    dev->pass();
    drain();
  }
  void drain() {
    for (const auto& n : dev->takeNotifications()) out += "N " + escape(n) + "\n";
    for (SoundId s : dev->takeSounds()) out += "S " + std::to_string(static_cast<int>(s)) + "\n";
  }
  void mark(const std::string& m) { out += "> " + m + "\n"; }
  void line(const std::string& l) {
    mark(l);
    const std::string w = l + "\n";
    dev->write(reinterpret_cast<const uint8_t*>(w.data()), w.size());
    dev->pass();
    drain();
  }
  void raw(const std::vector<uint8_t>& b) {
    mark("raw " + hex(b.data(), b.size()));
    dev->write(b.data(), b.size());
    dev->pass();
    drain();
  }
  void frame(const Color8& c, uint8_t br) {
    uint8_t f[8];
    golden::encodeFrame(seq++, c, br, f);
    raw(std::vector<uint8_t>(f, f + 8));
  }
  void advance(uint32_t ms) {
    mark("advance " + std::to_string(ms));
    dev->advance(ms);
    drain();
  }
  std::string finish() {
    advance(20000);  // let debounced persistence commit
    for (const auto& kv : dev->flash().data) out += "KV " + kv.first + "=" + hex(kv.second.data(), kv.second.size()) + "\n";
    const RenderParams& p = dev->lastParams();
    const std::vector<uint8_t> scene = golden::sceneBytes(p.scene);
    out += "P " + hex(scene.data(), scene.size()) + " sleeping=" +
           std::to_string(p.sleeping) + " fade=" + std::to_string(p.fadeMs) + "\n";
    out += "end\n";
    return out;
  }
};

std::string transcripts() {
  std::string out;
  {
    Transcript t("handshake");
    for (const char* c : {"INFO", "VERSION", "CAPS", "STATUS", "MODE_SETTINGS", "PRESET_LIST", "DIAG", "PING"}) t.line(c);
    for (int m = 1; m <= cfg::kNumModes; ++m) t.line("MODE_CAPABILITIES:" + std::to_string(m));
    out += t.finish();
  }
  {
    Transcript t("commands");
    t.dev->setMtu(247);
    for (const char* c :
         {"RGBW:1,2,3,4", "COLOR:200,100,50,25", "BRIGHTNESS:77", "MODE:4", "SPEED:3", "FREQUENCY:7",
          "FIREWORK_COLOR_MODE:1", "CLUB_COLOR_MODE:1", "POLICE_COLOR_MODE:1", "POLICE_COLOR_A:9,8,7,6",
          "POLICE_COLOR_B:1,2,3,255", "MODE_SPEED:6,9", "MODE_FREQUENCY:6,2", "STATUS", "MODE_SETTINGS", "MODE:4",
          "MODE:12", "SLEEP", "STATUS", "SLEEP", "WAKE", "WAKE", "SOUND_OFF", "SOUND_OFF", "SOUND_ON", "TIMER:5"}) {
      t.line(c);
    }
    t.advance(6000);  // timer expiry push
    for (const char* c : {"STATUS", "TIMER:120", "STATUS", "TIMER:0", "STATUS", " status ", "mode:2", "STATUS"}) t.line(c);
    out += t.finish();
  }
  {
    Transcript t("errors");
    t.dev->setMtu(247);
    for (const char* c :
         {"RGBW:1,2,3", "RGBW:1,2,3,4,5", "RGBW:256,0,0,0", "COLOR:a,b,c,d", "COLOR:1,,2,3", "BRIGHTNESS:300",
          "BRIGHTNESS:", "MODE:0", "MODE:14", "SPEED:0", "SPEED:11", "FREQUENCY:11", "FIREWORK_COLOR_MODE:2",
          "CLUB_COLOR_MODE:2", "POLICE_COLOR_MODE:2", "POLICE_COLOR_A:1,2,3", "POLICE_COLOR_B:1,2,3,4,5",
          "PRESET_SAVE:15", "PRESET_LOAD:3", "PRESET_DELETE:15", "MODE_SPEED:14,5", "MODE_SPEED:1,0",
          "MODE_FREQUENCY:0,5", "MODE_CAPABILITIES:14", "TIMER:86401", "TIMER:-1", "BOGUS", "", "STATUS:1",
          "PING:", "RGBW:99999999999,0,0,0", "RGBW:+1,0,0,0"}) {
      t.line(c);
    }
    t.line(std::string(120, 'A'));  // over-long line is discarded
    t.line("STATUS");
    out += t.finish();
  }
  {
    Transcript t("presets");
    t.dev->setMtu(247);
    for (const char* c : {"COLOR:10,20,30,40", "MODE:6", "MODE_SPEED:6,2", "PRESET_SAVE:0", "COLOR:1,1,1,1",
                          "MODE:11", "PRESET_SAVE:14", "PRESET_LIST", "PRESET_LOAD:0", "MODE_SETTINGS",
                          "PRESET_DELETE:0", "PRESET_LIST", "PRESET_LOAD:0", "SLEEP", "PRESET_LOAD:14"}) {
      t.line(c);
    }
    t.advance(16000);
    t.mark("reboot");
    t.dev->reboot();
    t.drain();
    t.open();
    for (const char* c : {"STATUS", "PRESET_LIST", "MODE_SETTINGS", "FACTORY_RESET", "STATUS", "PRESET_LIST"}) t.line(c);
    out += t.finish();
  }
  {
    Transcript t("binary");
    t.dev->setMtu(247);
    t.frame({255, 0, 0, 0}, 255);
    t.frame({0, 255, 0, 10}, 128);
    t.line("STATUS");
    t.raw({0xAA, 0x09, 1, 2, 3, 4, 5, 0x00});                   // bad checksum
    t.raw({0xAA, 11, 22, 33, 44, 55, static_cast<uint8_t>(11 ^ 22 ^ 33 ^ 44 ^ 55 ^ 0x55)});  // legacy 7
    t.line("STATUS");
    t.raw({0xAA, 5, 6, 7, 8, static_cast<uint8_t>(5 ^ 6 ^ 7 ^ 8 ^ 0x55)});                   // legacy 6
    t.line("STATUS");
    t.raw({0xAA, 1, 2, 3, 4});                                  // 5 bytes
    t.raw({0xAA, 1, 2, 3, 4, 5, 6, 7, 8});                      // 9 bytes
    t.line("STATUS");
    t.line("SLEEP");
    t.frame({9, 9, 9, 9}, 50);                                  // frames while asleep never wake
    t.line("STATUS");
    t.frame({1, 2, 3, 4}, 200);
    t.frame({1, 2, 3, 4}, 200);
    t.raw({0xAA, 200, 1, 2, 3, 4, 5, static_cast<uint8_t>(200 ^ 1 ^ 2 ^ 3 ^ 4 ^ 5 ^ 0x55)});  // seq gap
    t.line("DIAG");
    out += t.finish();
  }
  {
    Transcript t("mtu23_and_split");
    for (const char* c : {"MODE_SETTINGS", "STATUS", "DIAG"}) t.line(c);
    t.mark("split write");
    const char* a = "STA";
    const char* b = "TUS\nPI";
    const char* c = "NG\n";
    t.dev->write(reinterpret_cast<const uint8_t*>(a), 3);
    t.dev->write(reinterpret_cast<const uint8_t*>(b), 6);
    t.dev->pass();
    t.dev->write(reinterpret_cast<const uint8_t*>(c), 3);
    t.dev->pass();
    t.drain();
    t.mark("batch");
    const std::string many = "PING\nINFO\nVERSION\nCAPS\nMODE:3\nSTATUS\n";
    t.dev->write(reinterpret_cast<const uint8_t*>(many.data()), many.size());
    t.dev->pass();
    t.drain();
    out += t.finish();
  }
  {
    Transcript t("storage_failures");
    t.dev->setMtu(247);
    t.dev->flash().failWrites = true;
    for (const char* c : {"SOUND_OFF", "PRESET_SAVE:1", "PRESET_DELETE:1", "COLOR:5,5,5,5"}) t.line(c);
    t.advance(20000);
    t.dev->flash().failWrites = false;
    for (const char* c : {"SOUND_ON", "PRESET_SAVE:1", "PRESET_LIST", "DIAG"}) t.line(c);
    out += t.finish();
  }
  return out;
}

std::string readFile(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) return std::string();
  std::string s;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
  fclose(f);
  return s;
}

}  // namespace

TEST(golden_rgbw_matches_baseline) {
  const std::string actual = renderStreams() + transcripts();
  if (getenv("GOLDEN_RECORD") != nullptr) {
    FILE* f = fopen(kGoldenPath, "wb");
    CHECK(f != nullptr);
    if (f) {
      fwrite(actual.data(), 1, actual.size(), f);
      fclose(f);
      printf("    recorded %s (%zu bytes)\n", kGoldenPath, actual.size());
    }
    return;
  }
  const std::string expected = readFile(kGoldenPath);
  CHECK(!expected.empty());
  if (actual == expected) return;
  // Report the first differing line.
  size_t i = 0;
  while (i < actual.size() && i < expected.size() && actual[i] == expected[i]) ++i;
  const size_t ls = expected.rfind('\n', i == 0 ? 0 : i - 1);
  const size_t start = ls == std::string::npos ? 0 : ls + 1;
  const std::string exp = expected.substr(start, expected.find('\n', start) - start);
  const std::string act = actual.substr(start, actual.find('\n', start) - start);
  tf::fail(__FILE__, __LINE__, "golden mismatch\n      expected: " + exp + "\n      actual:   " + act);
}
