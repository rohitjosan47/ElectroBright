#include "StateStore.h"

#include <string.h>

#include "SceneCodec.h"

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

bool StateStore::readScene(const char* key, Scene& out) {
  uint8_t rec[scenecodec::kMaxRecord];
  const size_t n = scenecodec::recordSize(*fixture_.layout);
  return kv_.read(key, rec, n) && scenecodec::unpack(rec, n, *fixture_.layout, out);
}

bool StateStore::writeSceneRecord(const char* key, const Scene& s) {
  uint8_t rec[scenecodec::kMaxRecord];
  const size_t n = scenecodec::pack(s, *fixture_.layout, rec);
  return kv_.write(key, rec, n);
}

bool StateStore::noteWrite(bool ok) {
  Stats::inc(ok ? stats_.nvsWrites : stats_.nvsFailures);
  return ok;
}

void StateStore::load(Scene& scene, Settings& settings) {
  Scene stored;
  if (readScene(kSceneKey, stored)) {
    scene = stored;
    shadow_ = stored;
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
    Scene preset;
    if (readScene(key, preset)) {
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
  if (!noteWrite(writeSceneRecord(kSceneKey, scene))) {
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
  if (!noteWrite(writeSceneRecord(key, scene))) return false;
  presetMask_ |= (1u << id);
  return true;
}

bool StateStore::loadPreset(uint8_t id, Scene& out) {
  if (id >= cfg::kNumPresets) return false;
  char key[4];
  presetKey(id, key);
  if (readScene(key, out)) {
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
