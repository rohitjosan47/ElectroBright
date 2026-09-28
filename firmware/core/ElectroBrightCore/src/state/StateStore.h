#pragma once
// Persistence policy on top of IKeyValueStore.
//
//  * The live Scene is written with a debounce: kPersistDebounceMs after the
//    last change, and never later than kPersistMaxLatencyMs after the first
//    one (continuous slider streaming still gets saved). Unchanged data is
//    never rewritten (compared against a shadow copy of what is on flash).
//  * Settings and presets are written at once when the write budget allows
//    (WriteLimiter: cfg::kStorageMinIntervalMs apart, cfg::kStorageMaxPerMinute
//    a minute, shared with the scene). Beyond it they are held in RAM and
//    committed by tick() as the budget frees up: settings first, then preset
//    deletes and saves, then the scene. A newer value for the same record
//    replaces the held one; the last value is always written eventually.
//    Reads (presetMask, loadPreset) see held data. flushAll() commits
//    everything at once before a planned restart. While the last write
//    failed, requests are tried at once (and so report the failure).
//  * Every record carries a schema byte; anything that fails validation is
//    treated as absent and replaced by defaults.
//  * Presets carry a format marker ("pv"). Flash without the current one
//    holds presets of older firmware (up to 25 slots): they are erased once,
//    not migrated. The scene and settings are kept.

#include <stdint.h>

#include "../core/Stats.h"
#include "DeviceState.h"
#include "KeyValueStore.h"
#include "WriteLimiter.h"

class StateStore {
 public:
  static constexpr uint8_t kSchema = 1;  // settings record (scenes: SceneCodec)
  static constexpr uint8_t kPresetFormat = 2;  // "pv": 15 slots (older firmware: none, 25 slots)
  static constexpr uint8_t kLegacyPresetSlots = 25;  // p00..p24, erased by the one-time wipe

  StateStore(IKeyValueStore& kv, Stats& stats, const FixtureProfile& fixture)
      : kv_(kv), stats_(stats), fixture_(fixture) {}

  // Loads scene + settings (defaults for anything missing/invalid), clears
  // presets of an older format once, and scans which preset slots are
  // occupied.
  void load(Scene& scene, Settings& settings);

  // Live scene debounce.
  void noteSceneChanged(uint32_t nowMs);
  // Commits one held record, or the scene if due, when the budget allows.
  // Returns false if a write failed (the record stays held and is retried).
  bool tick(uint32_t nowMs, const Scene& scene);
  // Commits immediately if the scene differs from flash (outside the budget).
  bool flush(const Scene& scene);
  // Commits every held record and a changed scene now, outside the budget
  // (before a planned restart). False if any write failed.
  bool flushAll(const Scene& scene);
  bool hasPendingScene() const { return dirty_; }
  bool hasHeldWrites() const { return settingsHeld_ || heldSaves_ != 0 || heldDeletes_ != 0; }

  // True when written or held; false on an immediate write failure (the
  // settings then stay held and are retried).
  bool saveSettings(const Settings& settings, uint32_t nowMs);

  // True when written or held; false for a bad slot or scene, or an immediate
  // write failure (nothing is held then).
  bool savePreset(uint8_t id, const Scene& scene, uint32_t nowMs);
  bool loadPreset(uint8_t id, Scene& out);  // false if empty / invalid
  bool deletePreset(uint8_t id, uint32_t nowMs);
  uint32_t presetMask() const { return presetMask_; }  // bit i = slot i occupied

  // Erases every record and drops everything held; the caller then re-applies
  // defaults.
  bool factoryReset();

  // SET_TYPE: erases the scene and every preset slot (they belong to the old
  // layout) and drops held presets; settings stay (held ones too, for the
  // flushAll before the restart). The next boot starts from the new type's
  // defaults.
  bool clearForTypeChange();

 private:
  struct SettingsRecord {
    uint8_t schema;
    Settings settings;
  };

  static void presetKey(uint8_t id, char out[4]);
  void ensurePresetFormat();
  bool writeScene(const Scene& scene);
  bool writeSettings(const Settings& settings);
  bool noteWrite(bool ok);
  bool mayWriteNow(uint32_t nowMs) const;
  // Commit one held record (no budget check).
  bool commitSettings();
  bool commitHeldPreset(uint8_t id);
  bool commitNextHeld();

  bool valid(const Scene& s) const { return state::isValid(s, *fixture_.layout); }
  bool readScene(const char* key, Scene& out);
  bool writeSceneRecord(const char* key, const Scene& s);

  IKeyValueStore& kv_;
  Stats& stats_;
  const FixtureProfile& fixture_;
  Scene shadow_{};
  bool shadowValid_ = false;
  bool dirty_ = false;
  uint32_t firstDirtyMs_ = 0;
  uint32_t lastDirtyMs_ = 0;
  uint32_t presetMask_ = 0;

  WriteLimiter limiter_;
  bool failing_ = false;  // the last write failed
  bool settingsHeld_ = false;
  Settings heldSettings_{};
  uint32_t heldSaves_ = 0;    // bit i: heldPresets_[i] waits to be written
  uint32_t heldDeletes_ = 0;  // bit i: slot i waits to be erased
  Scene heldPresets_[cfg::kNumPresets] = {};
};
