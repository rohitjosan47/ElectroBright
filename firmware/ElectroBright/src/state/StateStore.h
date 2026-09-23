#pragma once
// Persistence policy on top of IKeyValueStore.
//
//  * The live Scene is written with a debounce: kPersistDebounceMs after the
//    last change, and never later than kPersistMaxLatencyMs after the first
//    one (continuous slider streaming still gets saved). Unchanged data is
//    never rewritten (compared against a shadow copy of what is on flash).
//  * Settings and presets are written immediately (rare, user-initiated).
//  * Every record carries a schema byte; anything that fails validation is
//    treated as absent and replaced by defaults.

#include <stdint.h>

#include "../core/Stats.h"
#include "DeviceState.h"
#include "KeyValueStore.h"

class StateStore {
 public:
  static constexpr uint8_t kSchema = 1;

  StateStore(IKeyValueStore& kv, Stats& stats) : kv_(kv), stats_(stats) {}

  // Loads scene + settings (defaults for anything missing/invalid) and scans
  // which preset slots are occupied.
  void load(Scene& scene, Settings& settings);

  // Live scene debounce.
  void noteSceneChanged(uint32_t nowMs);
  // Commits the scene if due. Returns false if a write failed.
  bool tick(uint32_t nowMs, const Scene& scene);
  // Commits immediately if the scene differs from flash.
  bool flush(const Scene& scene);
  bool hasPendingScene() const { return dirty_; }

  bool saveSettings(const Settings& settings);

  bool savePreset(uint8_t id, const Scene& scene);
  bool loadPreset(uint8_t id, Scene& out);  // false if empty / invalid
  bool deletePreset(uint8_t id);
  uint32_t presetMask() const { return presetMask_; }  // bit i = slot i occupied

  // Erases every record; the caller then re-applies defaults.
  bool factoryReset();

 private:
  struct SceneRecord {
    uint8_t schema;
    Scene scene;
  };
  struct SettingsRecord {
    uint8_t schema;
    Settings settings;
  };

  static void presetKey(uint8_t id, char out[4]);
  bool writeScene(const Scene& scene);
  bool noteWrite(bool ok);

  IKeyValueStore& kv_;
  Stats& stats_;
  Scene shadow_{};
  bool shadowValid_ = false;
  bool dirty_ = false;
  uint32_t firstDirtyMs_ = 0;
  uint32_t lastDirtyMs_ = 0;
  uint32_t presetMask_ = 0;
};
