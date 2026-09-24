// Persistence policy: defaults, validation, debounce, presets, factory reset.

#include "Fakes.h"
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
  std::vector<uint8_t> bad(1 + sizeof(Scene), 0);
  bad[0] = StateStore::kSchema;
  kv.data["p00"] = bad;
  // Wrong schema.
  Scene good = state::defaultScene(fx::rgbw::kProfile.defaults);
  std::vector<uint8_t> foreign(1 + sizeof(Scene), 0);
  foreign[0] = 99;
  memcpy(foreign.data() + 1, &good, sizeof(Scene));
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
