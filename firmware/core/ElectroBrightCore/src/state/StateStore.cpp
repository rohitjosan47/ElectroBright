#include "StateStore.h"

#include <string.h>

namespace {
constexpr const char* kSceneKey = "scene";
constexpr const char* kSettingsKey = "set";
}  // namespace

void StateStore::presetKey(uint8_t id, char out[4]) {
  out[0] = 'p';
  out[1] = static_cast<char>('0' + (id / 10) % 10);
  out[2] = static_cast<char>('0' + id % 10);
  out[3] = '\0';
}

bool StateStore::noteWrite(bool ok) {
  Stats::inc(ok ? stats_.nvsWrites : stats_.nvsFailures);
  return ok;
}

void StateStore::load(Scene& scene, Settings& settings) {
  SceneRecord sr;
  if (kv_.read(kSceneKey, &sr, sizeof(sr)) && sr.schema == kSchema && valid(sr.scene)) {
    scene = sr.scene;
    shadow_ = sr.scene;
    shadowValid_ = true;
  } else {
    scene = state::defaultScene(fixture_.defaults);
    shadowValid_ = false;  // first tick after a change (or flush) writes it
  }

  SettingsRecord st;
  if (kv_.read(kSettingsKey, &st, sizeof(st)) && st.schema == kSchema && state::isValid(st.settings)) {
    settings = st.settings;
  } else {
    settings = state::defaultSettings();
  }

  presetMask_ = 0;
  for (uint8_t i = 0; i < cfg::kNumPresets; ++i) {
    char key[4];
    presetKey(i, key);
    SceneRecord pr;
    if (kv_.read(key, &pr, sizeof(pr)) && pr.schema == kSchema && valid(pr.scene)) {
      presetMask_ |= (1u << i);
    }
  }
  dirty_ = false;
}

void StateStore::noteSceneChanged(uint32_t nowMs) {
  if (!dirty_) firstDirtyMs_ = nowMs;
  dirty_ = true;
  lastDirtyMs_ = nowMs;
}

bool StateStore::tick(uint32_t nowMs, const Scene& scene) {
  if (!dirty_) return true;
  const bool quiet = static_cast<uint32_t>(nowMs - lastDirtyMs_) >= cfg::kPersistDebounceMs;
  const bool overdue = static_cast<uint32_t>(nowMs - firstDirtyMs_) >= cfg::kPersistMaxLatencyMs;
  if (!quiet && !overdue) return true;
  return flush(scene);
}

bool StateStore::flush(const Scene& scene) {
  dirty_ = false;
  if (shadowValid_ && memcmp(&shadow_, &scene, sizeof(Scene)) == 0) return true;
  return writeScene(scene);
}

bool StateStore::writeScene(const Scene& scene) {
  SceneRecord sr;
  memset(&sr, 0, sizeof(sr));
  sr.schema = kSchema;
  sr.scene = scene;
  if (!noteWrite(kv_.write(kSceneKey, &sr, sizeof(sr)))) {
    // Keep it dirty so the next tick retries.
    dirty_ = true;
    return false;
  }
  shadow_ = scene;
  shadowValid_ = true;
  return true;
}

bool StateStore::saveSettings(const Settings& settings) {
  SettingsRecord st;
  memset(&st, 0, sizeof(st));
  st.schema = kSchema;
  st.settings = settings;
  return noteWrite(kv_.write(kSettingsKey, &st, sizeof(st)));
}

bool StateStore::savePreset(uint8_t id, const Scene& scene) {
  if (id >= cfg::kNumPresets || !valid(scene)) return false;
  char key[4];
  presetKey(id, key);
  SceneRecord pr;
  memset(&pr, 0, sizeof(pr));
  pr.schema = kSchema;
  pr.scene = scene;
  if (!noteWrite(kv_.write(key, &pr, sizeof(pr)))) return false;
  presetMask_ |= (1u << id);
  return true;
}

bool StateStore::loadPreset(uint8_t id, Scene& out) {
  if (id >= cfg::kNumPresets) return false;
  char key[4];
  presetKey(id, key);
  SceneRecord pr;
  if (kv_.read(key, &pr, sizeof(pr)) && pr.schema == kSchema && valid(pr.scene)) {
    out = pr.scene;
    presetMask_ |= (1u << id);
    return true;
  }
  presetMask_ &= ~(1u << id);
  return false;
}

bool StateStore::deletePreset(uint8_t id) {
  if (id >= cfg::kNumPresets) return false;
  char key[4];
  presetKey(id, key);
  const bool ok = kv_.erase(key);
  if (ok) presetMask_ &= ~(1u << id);
  return noteWrite(ok);
}

bool StateStore::factoryReset() {
  const bool ok = noteWrite(kv_.eraseAll());
  presetMask_ = 0;
  shadowValid_ = false;
  dirty_ = false;
  return ok;
}
