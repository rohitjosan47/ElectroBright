#include "StateStore.h"

#include <string.h>

#include "SceneCodec.h"

namespace {
constexpr const char* kSceneKey = "scene";
constexpr const char* kSettingsKey = "set";
constexpr const char* kPresetFormatKey = "pv";  // presets are "p00".."p24": no clash
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
  failing_ = !ok;
  return ok;
}

bool StateStore::mayWriteNow(uint32_t nowMs) const {
  // While the flash fails, a request is tried at once: it costs no wear, and
  // the caller learns the truth (retries would otherwise use up the budget).
  return failing_ || limiter_.allowed(nowMs);
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

  ensurePresetFormat();
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

void StateStore::ensurePresetFormat() {
  uint8_t format = 0;
  if (kv_.read(kPresetFormatKey, &format, sizeof(format)) && format == kPresetFormat) return;
  // Older firmware's presets (or none, on a new device): drop every slot it
  // could have used. A key that is already absent erases fine.
  bool cleared = true;
  for (uint8_t i = 0; i < kLegacyPresetSlots; ++i) {
    char key[4];
    presetKey(i, key);
    if (!kv_.erase(key)) {
      cleared = false;
      Stats::inc(stats_.nvsFailures);
    }
  }
  // Marked only once every old slot is gone; otherwise the next boot retries.
  if (!cleared) return;
  const uint8_t current = kPresetFormat;
  noteWrite(kv_.write(kPresetFormatKey, &current, sizeof(current)));
}

void StateStore::noteSceneChanged(uint32_t nowMs) {
  if (!dirty_) firstDirtyMs_ = nowMs;
  dirty_ = true;
  lastDirtyMs_ = nowMs;
}

bool StateStore::tick(uint32_t nowMs, const Scene& scene) {
  if (!limiter_.allowed(nowMs)) return true;
  if (hasHeldWrites()) {
    const bool ok = commitNextHeld();
    limiter_.note(nowMs, ok);
    return ok;
  }
  if (!dirty_) return true;
  const bool quiet = static_cast<uint32_t>(nowMs - lastDirtyMs_) >= cfg::kPersistDebounceMs;
  const bool overdue = static_cast<uint32_t>(nowMs - firstDirtyMs_) >= cfg::kPersistMaxLatencyMs;
  if (!quiet && !overdue) return true;
  if (shadowValid_ && memcmp(&shadow_, &scene, sizeof(Scene)) == 0) {
    dirty_ = false;  // nothing to write: no commit spent
    return true;
  }
  const bool ok = flush(scene);
  limiter_.note(nowMs, ok);
  return ok;
}

bool StateStore::flush(const Scene& scene) {
  dirty_ = false;
  if (shadowValid_ && memcmp(&shadow_, &scene, sizeof(Scene)) == 0) return true;
  return writeScene(scene);
}

bool StateStore::flushAll(const Scene& scene) {
  bool ok = true;
  // Each failed record stays held; one attempt each.
  if (settingsHeld_) ok = commitSettings() && ok;
  for (uint8_t i = 0; i < cfg::kNumPresets; ++i) {
    if ((heldSaves_ | heldDeletes_) & (1u << i)) ok = commitHeldPreset(i) && ok;
  }
  if (dirty_) ok = flush(scene) && ok;
  return ok;
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

bool StateStore::writeSettings(const Settings& settings) {
  SettingsRecord st;
  memset(&st, 0, sizeof(st));
  st.schema = kSchema;
  st.settings = settings;
  return noteWrite(kv_.write(kSettingsKey, &st, sizeof(st)));
}

bool StateStore::commitSettings() {
  const bool ok = writeSettings(heldSettings_);
  settingsHeld_ = !ok;
  return ok;
}

bool StateStore::commitHeldPreset(uint8_t id) {
  const uint32_t bit = 1u << id;
  char key[4];
  presetKey(id, key);
  if (heldDeletes_ & bit) {
    const bool ok = noteWrite(kv_.erase(key));
    if (ok) heldDeletes_ &= ~bit;
    return ok;
  }
  const bool ok = noteWrite(writeSceneRecord(key, heldPresets_[id]));
  if (ok) heldSaves_ &= ~bit;
  return ok;
}

bool StateStore::commitNextHeld() {
  if (settingsHeld_) return commitSettings();
  const uint32_t pending = heldDeletes_ ? heldDeletes_ : heldSaves_;
  for (uint8_t i = 0; i < cfg::kNumPresets; ++i) {
    if (pending & (1u << i)) return commitHeldPreset(i);
  }
  return true;
}

bool StateStore::saveSettings(const Settings& settings, uint32_t nowMs) {
  heldSettings_ = settings;
  settingsHeld_ = true;
  if (!mayWriteNow(nowMs)) return true;
  const bool ok = commitSettings();
  limiter_.note(nowMs, ok);
  return ok;
}

bool StateStore::savePreset(uint8_t id, const Scene& scene, uint32_t nowMs) {
  if (id >= cfg::kNumPresets || !valid(scene)) return false;
  const uint32_t bit = 1u << id;
  heldDeletes_ &= ~bit;
  if (!mayWriteNow(nowMs)) {
    heldPresets_[id] = scene;
    heldSaves_ |= bit;
    presetMask_ |= bit;
    return true;
  }
  heldSaves_ &= ~bit;
  char key[4];
  presetKey(id, key);
  const bool ok = noteWrite(writeSceneRecord(key, scene));
  limiter_.note(nowMs, ok);
  if (ok) presetMask_ |= bit;
  return ok;
}

bool StateStore::loadPreset(uint8_t id, Scene& out) {
  if (id >= cfg::kNumPresets) return false;
  const uint32_t bit = 1u << id;
  if (heldSaves_ & bit) {
    out = heldPresets_[id];
    return true;
  }
  if (heldDeletes_ & bit) return false;
  char key[4];
  presetKey(id, key);
  if (readScene(key, out)) {
    presetMask_ |= bit;
    return true;
  }
  presetMask_ &= ~bit;
  return false;
}

bool StateStore::deletePreset(uint8_t id, uint32_t nowMs) {
  if (id >= cfg::kNumPresets) return false;
  const uint32_t bit = 1u << id;
  heldSaves_ &= ~bit;
  if (!mayWriteNow(nowMs)) {
    heldDeletes_ |= bit;
    presetMask_ &= ~bit;
    return true;
  }
  heldDeletes_ &= ~bit;
  char key[4];
  presetKey(id, key);
  const bool ok = noteWrite(kv_.erase(key));
  limiter_.note(nowMs, ok);
  if (ok) presetMask_ &= ~bit;
  return ok;
}

bool StateStore::factoryReset() {
  const bool ok = noteWrite(kv_.eraseAll());
  presetMask_ = 0;
  shadowValid_ = false;
  dirty_ = false;
  settingsHeld_ = false;
  heldSaves_ = 0;
  heldDeletes_ = 0;
  return ok;
}

bool StateStore::clearForTypeChange() {
  bool ok = kv_.erase(kSceneKey);
  for (uint8_t i = 0; i < kLegacyPresetSlots; ++i) {
    char key[4];
    presetKey(i, key);
    ok = kv_.erase(key) && ok;
  }
  noteWrite(ok);
  presetMask_ = 0;
  shadowValid_ = false;
  dirty_ = false;
  heldSaves_ = 0;
  heldDeletes_ = 0;
  return ok;
}
