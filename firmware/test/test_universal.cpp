// The universal firmware (3.7.0): one image, the fixture type stored in the
// light. Boot selection, SET_TYPE, setup-needed mode, PROBE, and the type
// surviving FACTORY_RESET.

#include <string.h>

#include <set>
#include <string>
#include <vector>

#include "Fakes.h"
#include "Fixtures.h"
#include "TestFramework.h"
#include "fixture/FixtureSelect.h"
#include "fwsim/SimDevice.h"
#include "protocol/BinaryFrame.h"
#include "state/SceneCodec.h"

namespace {

const std::string kTypes = "TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,";

void writeText(SimDevice& d, const char* s) { d.write(reinterpret_cast<const uint8_t*>(s), strlen(s)); }

std::string received(SimDevice& d) {
  std::string s;
  for (const auto& n : d.takeNotifications()) s.append(n.begin(), n.end());
  return s;
}

void connectAndSubscribe(SimDevice& d) {
  d.connect();
  d.setMtu(247);
  d.setSubscribed(true);
  d.pass();
  d.takeSounds();
}

// Sends `lines` (newline added) and returns what the phone received.
std::string ask(SimDevice& d, const char* lines) {
  writeText(d, (std::string(lines) + "\n").c_str());
  d.pass();
  return received(d);
}

uint8_t storedType(MockKv& system) {
  auto it = system.data.find("fx");
  return it == system.data.end() || it->second.size() != 1 ? 0 : it->second[0];
}

bool hasPresetKeys(const MockKv& kv) {
  for (const auto& e : kv.data) {
    if (e.first.size() == 3 && e.first[0] == 'p' && e.first != "pv") return true;
  }
  return false;
}

}  // namespace

// ---- Boot: which type ---------------------------------------------------------------

TEST(universal_new_light_saves_and_uses_the_build_default) {
  for (const NamedFixture& nf : kAllFixtures) {
    MockKv system;
    const FixtureProfile& f = fxselect::select(system, nf.profile->type);
    CHECK(&f == nf.profile);
    CHECK_EQ(storedType(system), static_cast<uint8_t>(nf.profile->type));
  }
}

TEST(universal_stored_type_wins_over_the_build_default) {
  MockKv system;
  CHECK(fxselect::write(system, FixtureType::Cct));
  CHECK(&fxselect::select(system, FixtureType::Rgbw) == &profiles::kCct);
  CHECK(&fxselect::select(system, FixtureType::None) == &profiles::kCct);
  CHECK_EQ(storedType(system), static_cast<uint8_t>(FixtureType::Cct));
}

TEST(universal_build_without_default_never_invents_a_type) {
  MockKv system;
  CHECK(&fxselect::select(system, FixtureType::None) == &profiles::kNone);
  CHECK(system.data.empty());
  // A stored value that is not a type counts as missing.
  system.data["fx"] = {9};
  CHECK(&fxselect::select(system, FixtureType::None) == &profiles::kNone);
  CHECK(&fxselect::select(system, FixtureType::W) == &profiles::kW);
  CHECK_EQ(storedType(system), static_cast<uint8_t>(FixtureType::W));
}

TEST(universal_every_type_boots_from_the_stored_type) {
  for (const NamedFixture& nf : kAllFixtures) {
    SimDevice d(FixtureType::None);
    CHECK(fxselect::write(d.systemFlash(), nf.profile->type));
    d.reboot();
    CHECK(&d.fixture() == nf.profile);
    CHECK(!d.core().setupNeeded());
  }
}

// ---- SET_TYPE ---------------------------------------------------------------------------

TEST(set_type_persists_clears_presets_resets_scene_and_restarts) {
  SimDevice d;  // RGBW by default
  d.boot();
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "PRESET_SAVE:3\nPRESET_SAVE:14"), "OK\nOK\n");
  ask(d, "MODE:5\nSOUND_OFF");
  d.advance(cfg::kPersistMaxLatencyMs);  // scene on flash
  CHECK(d.flash().data.count("scene") == 1);
  CHECK(hasPresetKeys(d.flash()));

  CHECK_STR(ask(d, "SET_TYPE:CCT"), "OK\n");  // delivered before the restart
  CHECK_EQ(d.restarts(), 1);
  CHECK(!d.connected());  // the restart dropped the link
  CHECK_EQ(storedType(d.systemFlash()), static_cast<uint8_t>(FixtureType::Cct));
  CHECK(!hasPresetKeys(d.flash()));
  CHECK(&d.fixture() == &profiles::kCct);
  CHECK(d.core().scene().color == profiles::kCct.defaults.color);
  CHECK_EQ(d.core().scene().mode, 1);
  CHECK_EQ(d.store().presetMask(), 0u);
  CHECK_EQ(d.core().settings().soundEnabled, 0);  // settings are not layout data

  connectAndSubscribe(d);
  CHECK_STR(ask(d, "CAPS"), "CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1," + kTypes +
                                "LAYOUT=CCT,OTA=1310720\n");
  CHECK_STR(ask(d, "PRESET_LIST"), "PRESETS:\n");
  // A later power cycle keeps the new type.
  d.reboot();
  CHECK(&d.fixture() == &profiles::kCct);
}

TEST(set_type_same_type_is_a_no_op) {
  Rig r(profiles::kRgb);
  r.send("PRESET_SAVE:2");
  const auto before = r.kv.data;
  r.env.clear();
  r.send("SET_TYPE:RGB");
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(r.env.restarts, 0);
  CHECK(r.kv.data == before);
  CHECK(!r.core.restartPending());
  r.send("STATUS");  // still serving
  CHECK(r.env.last().rfind("STATUS:", 0) == 0);
}

TEST(set_type_rejects_invalid_types) {
  Rig r;
  for (const char* bad : {"SET_TYPE", "SET_TYPE:", "SET_TYPE:NONE", "SET_TYPE:RGBWW", "SET_TYPE:1", "SET_TYPE:RGB,",
                          "SET_TYPE:RGB CCT"}) {
    r.env.clear();
    r.send(bad);
    CHECK_STR(r.env.last(), "ERROR:TYPE_INVALID");
  }
  CHECK_EQ(r.env.restarts, 0);
  CHECK_EQ(storedType(r.system), static_cast<uint8_t>(FixtureType::Rgbw));
  // Names are case-insensitive like command names, blanks around them ignored.
  r.send("set_type: rgbcct ");
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(storedType(r.system), static_cast<uint8_t>(FixtureType::Rgbcct));
}

TEST(set_type_ignores_the_rest_of_the_batch) {
  Rig r;
  const char* lines[] = {"SET_TYPE:W", "PRESET_SAVE:1", "COLOR:1,2,3,4", "STATUS"};
  r.core.processLines(lines, 4, r.now);
  CHECK_EQ(r.env.lines.size(), size_t{1});
  CHECK_STR(r.env.last(), "OK");
  CHECK(!hasPresetKeys(r.kv));
  // Nothing is persisted for the old layout while the restart is pending.
  r.advance(cfg::kPersistMaxLatencyMs);
  CHECK(r.kv.data.count("scene") == 0);
  const Color8 shown = r.core.scene().color;
  ColorFrame f{};
  f.color = {1, 2, 3, 4};
  r.core.onColorFrame(f, r.now);
  CHECK(r.core.scene().color == shown);
  CHECK_EQ(r.env.restarts, 1);
}

TEST(set_type_storage_failure_keeps_the_type) {
  Rig r;
  r.kv.failWrites = true;
  r.send("SET_TYPE:CCT");
  CHECK_STR(r.env.last(), "ERROR:STORAGE");
  CHECK_EQ(r.env.restarts, 0);
  CHECK_EQ(storedType(r.system), static_cast<uint8_t>(FixtureType::Rgbw));
  CHECK(!r.core.restartPending());
}

// ---- Setup-needed mode -------------------------------------------------------------------

TEST(setup_needed_outputs_off_and_recognisable) {
  const FixtureProfile& f = profiles::kNone;
  CHECK_EQ(f.layout->count, 0);
  CHECK_EQ(f.parkLowCount, board::kNumOutputs);  // every LED output held low
  for (uint8_t i = 0; i < board::kNumOutputs; ++i) CHECK_EQ(f.parkLowPins[i], board::kOutputPins[i]);
  CHECK_STR(f.deviceName, "ElectroBright_C3_SETUP");
  CHECK(strlen(f.deviceName) <= 29);

  SimDevice d(FixtureType::None);
  d.boot();
  CHECK(d.core().setupNeeded());
  CHECK(d.systemFlash().data.empty());
  CHECK(d.flash().data.empty());  // nothing stored until SET_TYPE
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "CAPS"), "CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1," + kTypes +
                                "LAYOUT=NONE,OTA=1310720\n");
  CHECK_STR(ask(d, "VERSION"), std::string("VERSION:") + cfg::kFirmwareVersion + "\n");
  CHECK(ask(d, "DIAG").rfind("DIAG:rx=", 0) == 0);
}

TEST(setup_needed_accepts_only_the_setup_commands) {
  Rig r(profiles::kNone);
  for (const char* cmd : {"STATUS", "INFO", "PING", "COLOR", "COLOR:1,2,3,4", "MODE:1", "MODE:99", "BRIGHTNESS:9",
                          "SLEEP", "WAKE", "PRESET_SAVE:1", "PRESET_LOAD:1", "PRESET_LIST", "FACTORY_RESET",
                          "TIMER:10", "SOUND_OFF", "MODE_SETTINGS", "MODE_CAPABILITIES:1"}) {
    r.env.clear();
    r.send(cmd);
    CHECK_EQ(r.env.lines.size(), size_t{1});
    CHECK_STR(r.env.last(), "ERROR:SETUP_NEEDED");
  }
  r.env.clear();
  r.send("BOGUS");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  r.send("RGBW:1,2,3,4");  // the RGBW light's own alias: unknown without a layout
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  CHECK(r.kv.data.empty());

  // Binary colour frames change nothing.
  const RenderParams before = r.env.params;
  ColorFrame f{};
  f.color = {255, 255, 255, 255};
  f.hasBrightness = true;
  f.brightness = 255;
  r.core.onColorFrame(f, r.now);
  CHECK(r.core.scene().color == before.scene.color);

  // IDENTIFY: the buzzer only (always audible), no light flashes.
  r.env.clear();
  r.send("SOUND_OFF");  // rejected: mute cannot silence it either
  r.env.clear();
  r.send("IDENTIFY");
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(r.env.sounds.size(), size_t{1});
  CHECK(r.env.sounds[0] == SoundId::Identify);
  CHECK_EQ(r.env.params.identifyId, 0);

  for (const char* ok : {"CAPS", "VERSION", "DIAG", "PROBE:0:1", "PROBE:0:0"}) {
    r.env.clear();
    r.send(ok);
    CHECK(r.env.last().rfind("ERROR", 0) != 0);
  }
}

TEST(setup_needed_set_type_starts_the_new_type) {
  SimDevice d(FixtureType::None);
  d.boot();
  d.flash().data["p03"] = {1, 2, 3};  // an older firmware's leftovers
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "SET_TYPE:RGBCCT"), "OK\n");
  CHECK_EQ(d.restarts(), 1);
  CHECK(&d.fixture() == &profiles::kRgbcct);
  CHECK(!d.core().setupNeeded());
  CHECK(d.flash().data.count("p03") == 0);
  CHECK(d.core().scene().color == profiles::kRgbcct.defaults.color);
}

// ---- PROBE ---------------------------------------------------------------------------------

TEST(probe_routes_each_output_to_its_pin_for_every_type) {
  const uint8_t expectPins[board::kNumOutputs] = {1, 3, 4, 5, 10};
  std::vector<const FixtureProfile*> all;
  for (const NamedFixture& nf : kAllFixtures) all.push_back(nf.profile);
  all.push_back(&profiles::kNone);
  for (const FixtureProfile* f : all) {
    for (uint8_t out = 0; out < board::kNumOutputs; ++out) {
      const probe::Route r = probe::route(*f, out);
      CHECK_EQ(r.pin, expectPins[out]);
      uint16_t duty[kMaxChannels] = {100, 200, 300, 400, 500};
      const uint8_t extra = probe::apply(*f, static_cast<uint8_t>(out + 1), duty);
      if (r.channel != probe::kNoChannel) {
        CHECK_EQ(f->pins[r.channel], expectPins[out]);
        CHECK_EQ(extra, probe::kNoPin);
      } else {
        // Not in the layout: one of the parked outputs, driven on its own.
        bool parked = false;
        for (uint8_t i = 0; i < f->parkLowCount; ++i) parked |= f->parkLowPins[i] == expectPins[out];
        CHECK(parked);
        CHECK_EQ(extra, expectPins[out]);
      }
      for (uint8_t i = 0; i < f->layout->count; ++i) {
        CHECK_EQ(duty[i], i == r.channel ? cfg::kProbeDuty : 0);
      }
    }
    // Off: the rendered duties pass through.
    uint16_t duty[kMaxChannels] = {100, 200, 300, 400, 500};
    CHECK_EQ(probe::apply(*f, 0, duty), probe::kNoPin);
    CHECK_EQ(duty[0], 100);
  }
  // Spot checks of the mapping: warm on CCT is channel 1; white on RGB is parked.
  CHECK_EQ(probe::route(profiles::kCct, 4).channel, 1);
  CHECK_EQ(probe::route(profiles::kRgbcct, 3).channel, 3);
  CHECK_EQ(probe::route(profiles::kRgb, 3).channel, probe::kNoChannel);
  CHECK_EQ(probe::route(profiles::kW, 3).channel, 0);
}

TEST(probe_expires_after_three_seconds) {
  for (const NamedFixture& nf : kAllFixtures) {
    Rig r(*nf.profile);
    r.send("PROBE:2:1");
    CHECK_STR(r.env.last(), "OK");
    CHECK_EQ(r.env.params.probe, 3);
    r.advance(cfg::kProbeMs - 100);
    CHECK_EQ(r.env.params.probe, 3);
    r.advance(200);
    CHECK_EQ(r.env.params.probe, 0);
    CHECK_EQ(r.core.probeOutput(), -1);
  }
}

TEST(probe_one_output_at_a_time_and_off) {
  Rig r;
  r.send("PROBE:0:1");
  r.send("PROBE:4:1");
  CHECK_EQ(r.env.params.probe, 5);  // switched, not added
  r.send("PROBE:0:0");              // not the probed one: nothing changes
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(r.env.params.probe, 5);
  r.send("PROBE:4:0");
  CHECK_EQ(r.env.params.probe, 0);
  for (const char* bad : {"PROBE", "PROBE:5:1", "PROBE:1:2", "PROBE:1", "PROBE:1,1", "PROBE:1:1:1", "PROBE:a:1"}) {
    r.env.clear();
    r.send(bad);
    CHECK_STR(r.env.last(), "ERROR:PROBE_INVALID");
    CHECK_EQ(r.env.params.probe, 0);
  }
}

TEST(probe_is_cancelled_by_any_other_command) {
  for (const char* other : {"STATUS", "CAPS", "PING", "COLOR:1,2,3,4", "MODE:2", "IDENTIFY"}) {
    Rig r;
    r.send("PROBE:1:1");
    CHECK_EQ(r.env.params.probe, 2);
    r.send(other);
    CHECK_EQ(r.env.params.probe, 0);
  }
  // A binary colour frame too.
  Rig r;
  r.send("PROBE:1:1");
  ColorFrame f{};
  f.color = {1, 2, 3, 4};
  r.core.onColorFrame(f, r.now);
  CHECK_EQ(r.env.params.probe, 0);
  // And a probe ends a running IDENTIFY.
  r.send("IDENTIFY");
  CHECK(r.env.params.identifyId != 0);
  r.send("PROBE:1:1");
  CHECK_EQ(r.env.params.identifyId, 0);
  CHECK_EQ(r.env.params.probe, 2);
}

TEST(probe_persists_nothing_and_leaves_the_scene) {
  Rig r;
  r.advance(cfg::kPersistMaxLatencyMs);
  const auto flash = r.kv.data;
  const int writes = r.kv.writes;
  const Scene scene = r.core.scene();
  r.send("PROBE:3:1");
  r.advance(cfg::kProbeMs + cfg::kPersistMaxLatencyMs);
  CHECK(r.kv.data == flash);
  CHECK_EQ(r.kv.writes, writes);
  CHECK(memcmp(&scene, &r.core.scene(), sizeof(Scene)) == 0);
  CHECK(r.system.data.size() == 1);  // only the type
}

TEST(probe_works_in_setup_needed_mode) {
  Rig r(profiles::kNone);
  r.send("PROBE:4:1");
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(r.env.params.probe, 5);
  uint16_t duty[kMaxChannels] = {};
  CHECK_EQ(probe::apply(profiles::kNone, r.env.params.probe, duty), board::kPinWarm);
  r.advance(cfg::kProbeMs);
  CHECK_EQ(r.env.params.probe, 0);
  CHECK(r.kv.data.empty());
}

// ---- FACTORY_RESET ---------------------------------------------------------------------------

TEST(factory_reset_keeps_the_fixture_type) {
  SimDevice d;
  d.boot();
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "SET_TYPE:W"), "OK\n");
  connectAndSubscribe(d);
  CHECK_STR(ask(d, "PRESET_SAVE:1"), "OK\n");
  CHECK_STR(ask(d, "FACTORY_RESET"), "OK\n");
  CHECK(!hasPresetKeys(d.flash()));
  CHECK_EQ(storedType(d.systemFlash()), static_cast<uint8_t>(FixtureType::W));
  d.reboot();
  CHECK(&d.fixture() == &profiles::kW);  // not the build default (RGBW)
}

// ---- Unused outputs ------------------------------------------------------------------------

TEST(unused_outputs_are_held_low_per_type) {
  struct Expect {
    const FixtureProfile* f;
    std::set<int> parked;
  };
  const Expect expects[] = {
      {&profiles::kRgbw, {10}},        {&profiles::kRgb, {5, 10}},        {&profiles::kRgbcct, {}},
      {&profiles::kCct, {1, 3, 4}},    {&profiles::kW, {1, 3, 4, 10}},    {&profiles::kNone, {1, 3, 4, 5, 10}},
  };
  for (const Expect& e : expects) {
    std::set<int> parked;
    for (uint8_t i = 0; i < e.f->parkLowCount; ++i) parked.insert(e.f->parkLowPins[i]);
    CHECK(parked == e.parked);
    for (uint8_t i = 0; i < e.f->layout->count; ++i) CHECK(parked.count(e.f->pins[i]) == 0);
  }
}
