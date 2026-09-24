// Invariants every fixture profile (fixtures/*/Fixture.h) must satisfy, run for
// each entry of kAllFixtures: identity, wiring, protocol widths, binary frame
// routing and rendering. A new fixture is covered by adding it to Fixtures.h.

#include <string.h>

#include <set>
#include <string>

#include "Fakes.h"
#include "Fixtures.h"
#include "TestFramework.h"
#include "core/Rng.h"
#include "fwsim/SimDevice.h"
#include "protocol/BinaryFrame.h"
#include "render/RenderEngine.h"

namespace {

size_t fieldCount(const std::string& line) {
  const size_t colon = line.find(':');
  if (colon == std::string::npos) return 0;
  size_t n = 1;
  for (size_t i = colon + 1; i < line.size(); ++i) n += line[i] == ',';
  return n;
}

bool endsWith(const std::string& s, const std::string& tail) {
  return s.size() >= tail.size() && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}

}  // namespace

TEST(fixtures_identity_is_consistent_and_unique) {
  std::set<std::string> models, names, namespaces, cli;
  for (const NamedFixture& nf : kAllFixtures) {
    const FixtureProfile& f = *nf.profile;
    const std::string layoutName = f.layout->name;
    CHECK(f.layout->count >= 1 && f.layout->count <= kMaxChannels);
    CHECK_STR(f.modelId, "EB-C3-" + layoutName + "-V1");
    CHECK(endsWith(f.capsReply, ",LAYOUT=" + layoutName));
    CHECK(strncmp(f.capsReply, "CAPS:PROTOCOL=1,", 16) == 0);
    CHECK(strncmp(f.deviceName, "ElectroBright_C3_", 17) == 0);
    CHECK(strlen(f.deviceName) <= 29);  // fits the 31-byte scan response
    CHECK(strlen(f.nvsNamespace) >= 1 && strlen(f.nvsNamespace) <= 15);
    CHECK(models.insert(f.modelId).second);
    CHECK(names.insert(f.deviceName).second);
    CHECK(namespaces.insert(f.nvsNamespace).second);
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
    CHECK(f.parkLowCount <= 2);
    for (uint8_t i = 0; i < f.parkLowCount; ++i) CHECK(pins.insert(f.parkLowPins[i]).second);
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
    CHECK_STR(r.env.last(), nf.profile->capsReply);
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
          const Rgbw8 c = layout::fromTuple(*nf.profile->layout, r.cmd.args);
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
      const Rgbw8 c = layout::fromTuple(l, v);
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
    const ChannelLayout& l = *nf.profile->layout;
    SimDevice d(*nf.profile);
    d.boot();
    d.connect();
    d.setMtu(247);
    d.setSubscribed(true);
    d.pass();
    // Every 0xAA write in the binary length window (bad checksums included).
    const size_t lo = binframe::frameLength(l) < 6 ? binframe::frameLength(l) : 6;
    const size_t hi = binframe::frameLength(l) > 8 ? binframe::frameLength(l) : 8;
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
