// Persistence policy: defaults, validation, debounce, presets, factory reset.

#include "Fakes.h"
#include "Fixtures.h"
#include "state/SceneCodec.h"
#include "TestFramework.h"

TEST(store_empty_flash_gives_defaults_and_no_presets) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store.load(s, set);
  const Scene d = state::defaultScene(fx::rgbw::kProfile.defaults);
  CHECK(memcmp(&s, &d, sizeof(Scene)) == 0);
  CHECK_EQ(set.soundEnabled, 1);
  CHECK_EQ(store.presetMask(), 0u);
  CHECK_EQ(kv.writes, 0);  // loading never writes
}

TEST(store_debounces_scene_writes) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store.load(s, set);

  s.color = {1, 2, 3, 4};
  store.noteSceneChanged(0);
  store.tick(1000, s);
  CHECK_EQ(kv.writes, 0);
  store.tick(2999, s);
  CHECK_EQ(kv.writes, 0);
  store.tick(3000, s);
  CHECK_EQ(kv.writes, 1);
  store.tick(10000, s);
  CHECK_EQ(kv.writes, 1);  // nothing pending

  // Unchanged data is never rewritten.
  store.noteSceneChanged(20000);
  store.tick(30000, s);
  CHECK_EQ(kv.writes, 1);
}

TEST(store_max_latency_bounds_continuous_streaming) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store.load(s, set);
  // A change every 100 ms forever: the debounce alone would never fire.
  uint32_t t = 0;
  for (; t < 20000; t += 100) {
    s.color.r = static_cast<uint8_t>(t / 100);
    store.noteSceneChanged(t);
    store.tick(t, s);
    if (kv.writes > 0) break;
  }
  CHECK_EQ(kv.writes, 1);
  CHECK(t >= cfg::kPersistMaxLatencyMs && t < cfg::kPersistMaxLatencyMs + 200);
}

TEST(store_scene_and_settings_round_trip) {
  MockKv kv;
  Stats st;
  {
    StateStore store(kv, st, fx::rgbw::kProfile);
    Scene s;
    Settings set;
    store.load(s, set);
    s.mode = 9;
    s.speed[8] = 10;
    s.policeB = {9, 8, 7, 6};
    store.noteSceneChanged(0);
    CHECK(store.flush(s));
    set.soundEnabled = 0;
    CHECK(store.saveSettings(set));
  }
  StateStore store2(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store2.load(s, set);
  CHECK_EQ(s.mode, 9);
  CHECK_EQ(s.speed[8], 10);
  CHECK_EQ(s.policeB.g, 8);
  CHECK_EQ(set.soundEnabled, 0);
}

TEST(store_rejects_corrupt_or_foreign_records) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  // Wrong size.
  kv.data["scene"] = std::vector<uint8_t>(5, 0);
  // Right size, invalid mode.
  std::vector<uint8_t> bad(scenecodec::recordSize(layouts::kRgbw), 0);
  bad[0] = scenecodec::kSchema;
  kv.data["p00"] = bad;
  // Wrong schema.
  Scene good = state::defaultScene(fx::rgbw::kProfile.defaults);
  std::vector<uint8_t> foreign(scenecodec::recordSize(layouts::kRgbw), 0);
  scenecodec::pack(good, layouts::kRgbw, foreign.data());
  foreign[0] = 99;
  kv.data["p01"] = foreign;

  Scene s;
  Settings set;
  store.load(s, set);
  CHECK_EQ(s.mode, 1);
  CHECK_EQ(store.presetMask(), 0u);
  Scene out;
  CHECK(!store.loadPreset(0, out));
  CHECK(!store.loadPreset(1, out));
}

TEST(store_presets_save_load_delete_and_mask) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store.load(s, set);
  s.mode = 12;
  CHECK(store.savePreset(0, s));
  s.mode = 4;
  CHECK(store.savePreset(24, s));
  CHECK_EQ(store.presetMask(), (1u << 0) | (1u << 24));
  CHECK(!store.savePreset(25, s));

  Scene out;
  CHECK(store.loadPreset(0, out));
  CHECK_EQ(out.mode, 12);
  CHECK(store.deletePreset(0));
  CHECK(!store.loadPreset(0, out));
  CHECK_EQ(store.presetMask(), 1u << 24);
  CHECK(store.deletePreset(5));  // deleting an empty slot is fine

  // Presets survive a reload (mask rebuilt from flash).
  StateStore store2(kv, st, fx::rgbw::kProfile);
  store2.load(s, set);
  CHECK_EQ(store2.presetMask(), 1u << 24);
}

TEST(store_factory_reset_erases_everything) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store.load(s, set);
  store.savePreset(3, s);
  set.soundEnabled = 0;
  store.saveSettings(set);
  CHECK(store.factoryReset());
  CHECK_EQ(store.presetMask(), 0u);
  CHECK(kv.data.empty());
}

TEST(store_retries_after_write_failure) {
  MockKv kv;
  Stats st;
  StateStore store(kv, st, fx::rgbw::kProfile);
  Scene s;
  Settings set;
  store.load(s, set);
  kv.failWrites = true;
  s.color.r = 7;
  store.noteSceneChanged(0);
  CHECK(!store.tick(5000, s));
  CHECK(store.hasPendingScene());
  CHECK_EQ(Stats::get(st.nvsFailures), 1u);
  kv.failWrites = false;
  CHECK(store.tick(5100, s));
  CHECK(!store.hasPendingScene());
  CHECK(kv.data.count("scene") == 1);
}

TEST(codec_keeps_the_legacy_flash_format_for_layouts_without_warm_white) {
  // RGBW / RGB records must stay byte-identical to firmware 3.4.0 (a schema
  // byte followed by the old 43-byte struct), so presets survive updates.
  Scene s = state::defaultScene(fx::rgbw::kProfile.defaults);
  s.color = {1, 2, 3, 4};
  s.brightness = 5;
  s.mode = 6;
  s.speed[0] = 7;
  s.freq[12] = 8;
  s.policeA = {9, 10, 11, 12};
  s.policeB = {13, 14, 15, 16};
  uint8_t rec[scenecodec::kMaxRecord];
  for (const ChannelLayout* l : {&layouts::kRgbw, &layouts::kRgb}) {
    Scene t = s;
    if (l == &layouts::kRgb) t.color.w = t.policeA.w = t.policeB.w = 0;
    CHECK_EQ(scenecodec::pack(t, *l, rec), size_t{44});
    const uint8_t expectedHead[] = {1, 1, 2, 3, static_cast<uint8_t>(l == &layouts::kRgb ? 0 : 4), 5, 6, 7};
    CHECK(memcmp(rec, expectedHead, sizeof(expectedHead)) == 0);
    CHECK_EQ(rec[1 + 4 + 1 + 1 + 13 + 12], 8);  // freq[12]
    CHECK_EQ(rec[40], 13);                      // policeB.r at 1 + 39
  }
}

TEST(codec_round_trips_every_fixture_and_rejects_bad_records) {
  for (const NamedFixture& nf : kAllFixtures) {
    const ChannelLayout& l = *nf.profile->layout;
    Scene s = state::defaultScene(nf.profile->defaults);
    s.mode = 9;
    s.speed[8] = 2;
    uint8_t rec[scenecodec::kMaxRecord];
    const size_t n = scenecodec::pack(s, l, rec);
    CHECK_EQ(n, scenecodec::recordSize(l));
    Scene back{};
    CHECK(scenecodec::unpack(rec, n, l, back));
    CHECK(memcmp(&back, &s, sizeof(Scene)) == 0);
    CHECK(!scenecodec::unpack(rec, n - 1, l, back));  // wrong size
    rec[0] = 2;
    CHECK(!scenecodec::unpack(rec, n, l, back));  // wrong schema
    rec[0] = scenecodec::kSchema;
    rec[6] = 0;  // mode 0
    CHECK(!scenecodec::unpack(rec, n, l, back));
  }
}
