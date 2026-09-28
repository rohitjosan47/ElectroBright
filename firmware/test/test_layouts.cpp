// Invariants every profile of the table (core fixture/Profiles.h) must
// satisfy, run for each entry of kAllFixtures: identity, wiring, protocol
// widths, binary frame routing and rendering. A new type is covered by adding
// it to Fixtures.h.

#include <stdio.h>
#include <string.h>

#include <map>
#include <set>
#include <string>

#include "Fakes.h"
#include "Fixtures.h"
#include "TestFramework.h"
#include "core/Rng.h"
#include "fwsim/SimDevice.h"
#include "protocol/BinaryFrame.h"
#include "protocol/Replies.h"
#include "render/RenderEngine.h"

namespace {

size_t fieldCount(const std::string& line) {
  const size_t colon = line.find(':');
  if (colon == std::string::npos) return 0;
  size_t n = 1;
  for (size_t i = colon + 1; i < line.size(); ++i) n += line[i] == ',';
  return n;
}

// CAPS:KEY=VALUE,... -> map. A part without '=' continues the previous value
// (TYPES=RGBW,RGB,...).
std::map<std::string, std::string> capsFields(const std::string& caps) {
  std::map<std::string, std::string> out;
  std::string last;
  size_t start = caps.find(':') + 1;
  while (start < caps.size()) {
    size_t end = caps.find(',', start);
    if (end == std::string::npos) end = caps.size();
    const std::string part = caps.substr(start, end - start);
    const size_t eq = part.find('=');
    if (eq != std::string::npos) {
      last = part.substr(0, eq);
      out[last] = part.substr(eq + 1);
    } else if (!last.empty()) {
      out[last] += "," + part;
    }
    start = end + 1;
  }
  return out;
}

std::string capsOf(const FixtureProfile& f) {
  char buf[256];
  replies::caps(buf, sizeof(buf), f, 0);  // Rig: no update slot
  return buf;
}

}  // namespace

TEST(fixtures_identity_is_consistent_and_unique) {
  std::set<std::string> models, names, cli;
  std::set<int> types;
  for (const NamedFixture& nf : kAllFixtures) {
    const FixtureProfile& f = *nf.profile;
    const std::string layoutName = f.layout->name;
    CHECK(f.layout->count >= 1 && f.layout->count <= kMaxChannels);
    CHECK_STR(f.modelId, "EB-C3-" + layoutName + "-V1");
    const std::map<std::string, std::string> caps = capsFields(capsOf(f));
    CHECK(caps.count("LAYOUT") == 1 && caps.at("LAYOUT") == layoutName);
    CHECK(capsOf(f).rfind("CAPS:PROTOCOL=1,", 0) == 0);
    CHECK(caps.count("TYPES") == 1 && caps.at("TYPES") == "RGBW,RGB,RGBCCT,CCT,W");
    CHECK(caps.count("PROBE") == 1 && caps.at("PROBE") == "1");
    CHECK(&profiles::forType(f.type) == &f);
    CHECK(profiles::forName(layoutName.c_str(), layoutName.size()) == &f);
    CHECK(types.insert(static_cast<int>(f.type)).second);
    // MODES (hex mask) is announced exactly when some mode is unsupported.
    if (f.layout->modes == kAllModes) {
      CHECK(caps.count("MODES") == 0);
    } else {
      char hex[8];
      snprintf(hex, sizeof(hex), "%X", f.layout->modes);
      CHECK(caps.count("MODES") == 1 && caps.at("MODES") == hex);
    }
    CHECK(strncmp(f.deviceName, "ElectroBright_C3_", 17) == 0);
    CHECK(strlen(f.deviceName) <= 29);  // fits the 31-byte scan response
    CHECK(models.insert(f.modelId).second);
    CHECK(names.insert(f.deviceName).second);
    CHECK(cli.insert(nf.name).second);
    // Defaults fit the layout (channels it lacks are 0).
    CHECK(layout::fits(*f.layout, f.defaults.color));
    CHECK(layout::fits(*f.layout, f.defaults.policeA));
    CHECK(layout::fits(*f.layout, f.defaults.policeB));
    // A 4-channel layout is RGBW-compatible on the wire only if it is RGBW.
    CHECK(!f.legacyFrames || layoutName == "RGBW");
  }
}

TEST(fixtures_wiring_uses_each_gpio_once) {
  for (const NamedFixture& nf : kAllFixtures) {
    const FixtureProfile& f = *nf.profile;
    std::set<int> pins;
    for (uint8_t i = 0; i < f.layout->count; ++i) CHECK(pins.insert(f.pins[i]).second);
    CHECK(pins.insert(f.buzzerPin).second);
    CHECK(f.parkLowCount <= 5);
    for (uint8_t i = 0; i < f.parkLowCount; ++i) CHECK(pins.insert(f.parkLowPins[i]).second);
    // Driven + parked = exactly the board's five LED outputs: nothing floats.
    std::set<int> leds(pins);
    leds.erase(f.buzzerPin);
    CHECK_EQ(leds.size(), size_t{board::kNumOutputs});
    for (uint8_t pin : board::kOutputPins) CHECK(leds.count(pin) == 1);
    for (int p : pins) CHECK(p != 2 && p != 8 && p != 9 && p != 7);  // strapping / old status LED
    // The buzzer's LEDC channel is the first one after the LED outputs.
    CHECK(f.layout->count < 6);
  }
}

TEST(fixtures_status_has_3n_plus_11_fields) {
  for (const NamedFixture& nf : kAllFixtures) {
    Rig r(*nf.profile);
    r.send("STATUS");
    CHECK_EQ(fieldCount(r.env.last()), size_t{3u * nf.profile->layout->count + 11u});
    r.send("CAPS");
    CHECK_STR(r.env.last(), capsOf(*nf.profile));
    r.send("INFO");
    CHECK_STR(r.env.last(), std::string("INFO:") + nf.profile->modelId);
  }
}

TEST(fixtures_colour_commands_take_one_value_per_channel) {
  for (const NamedFixture& nf : kAllFixtures) {
    const uint8_t n = nf.profile->layout->count;
    for (uint8_t k = 1; k <= kMaxChannels; ++k) {
      for (const char* cmd : {"COLOR", "POLICE_COLOR_A", "POLICE_COLOR_B"}) {
        std::string line = std::string(cmd) + ":";
        for (uint8_t i = 0; i < k; ++i) line += (i ? "," : "") + std::to_string(10 + i);
        const ParseResult r = parseCommand(line.c_str(), *nf.profile->layout);
        CHECK((r.status == ParseStatus::Ok) == (k == n));
        if (k == n) {
          const Color8 c = layout::fromTuple(*nf.profile->layout, r.cmd.args);
          uint8_t back[kMaxChannels];
          layout::toTuple(*nf.profile->layout, c, back);
          for (uint8_t i = 0; i < n; ++i) CHECK_EQ(back[i], 10 + i);
        }
      }
    }
  }
}

TEST(fixtures_binary_frames_round_trip_and_reject_other_layouts) {
  Rng rng(42);
  for (const NamedFixture& nf : kAllFixtures) {
    const ChannelLayout& l = *nf.profile->layout;
    for (int i = 0; i < 500; ++i) {
      uint8_t v[kMaxChannels];
      for (uint8_t k = 0; k < l.count; ++k) v[k] = static_cast<uint8_t>(rng.next());
      const Color8 c = layout::fromTuple(l, v);
      const uint8_t seq = static_cast<uint8_t>(rng.next());
      const uint8_t br = static_cast<uint8_t>(rng.next());
      uint8_t f[binframe::kMaxFrame];
      const size_t len = binframe::encode(seq, l, c, br, f);
      CHECK_EQ(len, size_t{l.count + 4u});
      ColorFrame out{};
      CHECK(binframe::decode(f, len, l, nf.profile->legacyFrames, out));
      CHECK(out.color == c && out.seq == seq && out.brightness == br);
      f[2] = static_cast<uint8_t>(f[2] ^ 1);  // any corruption fails the checksum
      CHECK(!binframe::decode(f, len, l, nf.profile->legacyFrames, out));
    }
    // Frames encoded for every other layout are rejected.
    for (const NamedFixture& other : kAllFixtures) {
      if (other.profile->layout == &l) continue;
      uint8_t f[binframe::kMaxFrame];
      const size_t len = binframe::encode(7, *other.profile->layout, {1, 2, 3, 0}, 9, f);
      ColorFrame out{};
      CHECK(!binframe::decode(f, len, l, nf.profile->legacyFrames, out));
    }
  }
}

TEST(fixtures_binary_writes_never_reach_the_text_parser) {
  for (const NamedFixture& nf : kAllFixtures) {
    SimDevice d(*nf.profile);
    d.boot();
    d.connect();
    d.setMtu(247);
    d.setSubscribed(true);
    d.pass();
    // Every 0xAA write of any family frame length (bad checksums included):
    // frames meant for another fixture must never corrupt the text stream.
    const size_t lo = binframe::kMinFrame;
    const size_t hi = binframe::kMaxFrame;
    for (size_t len = lo; len <= hi; ++len) {
      uint8_t junk[binframe::kMaxFrame + 1] = {0xAA, 1, 2, 3, 4, 5, 6, 7, 8, 9};
      junk[len - 1] = '\n';  // even a trailing newline must not splice text
      d.write(junk, len);
    }
    const char* ping = "PING\n";
    d.write(reinterpret_cast<const uint8_t*>(ping), 5);
    d.pass();
    std::string got;
    for (const auto& n : d.takeNotifications()) got.append(n.begin(), n.end());
    CHECK_STR(got, "OK\n");
    CHECK_EQ(Stats::get(d.stats().rxRejectedBytes), 0u);
  }
}

TEST(fixtures_every_mode_renders_bounded_and_sleeps_dark) {
  constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;
  for (const NamedFixture& nf : kAllFixtures) {
    const FixtureProfile& f = *nf.profile;
    for (uint8_t mode = 1; mode <= cfg::kNumModes; ++mode) {
      RenderEngine engine(mode, *f.layout, f.whiteMix);
      RenderParams p{};
      p.scene = state::defaultScene(f.defaults);
      p.scene.mode = mode;
      p.fadeMs = cfg::kSleepFadeMs;
      // Guard slots after the layout's channels must stay untouched.
      uint16_t duty[kMaxChannels + 1];
      for (uint16_t& d : duty) d = 0xBEEF;
      uint32_t now = 0;
      for (int i = 0; i < 1000; ++i, now += kFrameMs) {
        engine.frame(p, now, duty);
        for (uint8_t k = 0; k < f.layout->count; ++k) CHECK(duty[k] <= cfg::kPwmMaxDuty);
      }
      for (uint8_t k = f.layout->count; k <= kMaxChannels; ++k) CHECK_EQ(duty[k], 0xBEEF);
      p.sleeping = 1;
      for (int i = 0; i < 200; ++i, now += kFrameMs) engine.frame(p, now, duty);
      for (uint8_t k = 0; k < f.layout->count; ++k) CHECK_EQ(duty[k], 0);
    }
  }
}

TEST(fixtures_accept_exactly_their_supported_modes) {
  for (const NamedFixture& nf : kAllFixtures) {
    const ChannelLayout& l = *nf.profile->layout;
    Rig r(*nf.profile);
    for (int m = 0; m <= cfg::kNumModes + 1; ++m) {
      const bool ok = layout::supportsMode(l, m);
      const std::string ms = std::to_string(m);
      CHECK((parseCommand(("MODE:" + ms).c_str(), l).status == ParseStatus::Ok) == ok);
      CHECK((parseCommand(("MODE_SPEED:" + ms + ",3").c_str(), l).status == ParseStatus::Ok) == ok);
      CHECK((parseCommand(("MODE_FREQUENCY:" + ms + ",3").c_str(), l).status == ParseStatus::Ok) == ok);
      CHECK((parseCommand(("MODE_CAPABILITIES:" + ms).c_str(), l).status == ParseStatus::Ok) == ok);
      if (m >= 1 && m <= cfg::kNumModes) {
        Scene s = state::defaultScene(nf.profile->defaults);
        s.mode = static_cast<uint8_t>(m);
        CHECK(state::isValid(s, l) == ok);  // a stored unsupported mode is rejected
      }
    }
    // MODE_SETTINGS keeps all 13 pairs on every fixture.
    r.send("MODE_SETTINGS");
    size_t pairs = 1;
    for (char c : r.env.last()) pairs += c == ';';
    CHECK_EQ(pairs, size_t{cfg::kNumModes});
  }
}

