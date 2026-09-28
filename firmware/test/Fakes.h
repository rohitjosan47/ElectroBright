#pragma once
// Host-side fakes for the platform interfaces.

#include <map>
#include <string>
#include <vector>

#include "control/ControllerCore.h"
#include "fixture/FixtureSelect.h"
#include "ota/OtaFlash.h"
#include "state/KeyValueStore.h"

class MockKv : public IKeyValueStore {
 public:
  bool read(const char* key, void* out, size_t len) override {
    auto it = data.find(key);
    if (it == data.end() || it->second.size() != len) return false;
    memcpy(out, it->second.data(), len);
    return true;
  }
  bool write(const char* key, const void* src, size_t len) override {
    ++writes;
    if (failWrites) return false;
    const uint8_t* p = static_cast<const uint8_t*>(src);
    data[key] = std::vector<uint8_t>(p, p + len);
    return true;
  }
  bool erase(const char* key) override {
    ++erases;
    if (failWrites) return false;
    data.erase(key);
    return true;
  }
  bool eraseAll() override {
    if (failWrites) return false;
    data.clear();
    return true;
  }

  // Flash already on the current preset format (no one-time wipe on load).
  void markPresetFormat() { data["pv"] = {StateStore::kPresetFormat}; }

  std::map<std::string, std::vector<uint8_t>> data;
  int writes = 0;
  int erases = 0;
  bool failWrites = false;
};

class FakeEnv : public IControllerEnv {
 public:
  void sendLine(const char* line) override { lines.push_back(line); }
  void publish(const RenderParams& p) override {
    params = p;
    ++publishes;
  }
  void playSound(SoundId id) override { sounds.push_back(id); }
  void systemDiag(SystemDiag& d) override {
    d.minFreeHeap = 123456;
    d.uptimeSec = 42;
  }
  void restart() override { ++restarts; }

  std::string last() const { return lines.empty() ? std::string() : lines.back(); }
  void clear() {
    lines.clear();
    sounds.clear();
  }

  std::vector<std::string> lines;
  std::vector<SoundId> sounds;
  RenderParams params{};
  int publishes = 0;
  int restarts = 0;
};

// Two OTA app slots in RAM plus the bootloader's rollback rules
// (ESP-IDF, CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE):
//  * setBoot() marks the spare slot NEW and selects it;
//  * booting a NEW slot makes it PENDING_VERIFY;
//  * booting a PENDING_VERIFY slot again (it never confirmed) marks it ABORTED
//    and boots the other slot: the rollback.
// A slot's image is valid when it starts with the ESP image magic 0xE9.
class MockOtaFlash : public IOtaFlash {
 public:
  enum class SlotState : uint8_t { Valid, New, PendingVerify, Aborted, Invalid };

  size_t spareSize() override { return capacity; }
  Status begin() override {
    if (state[running] == SlotState::PendingVerify) return Status::Busy;
    if (failBegin) return Status::Error;
    slot[spare()].clear();
    open = true;
    ++begins;
    return Status::Ok;
  }
  Status resume(size_t offset) override {
    if (state[running] == SlotState::PendingVerify) return Status::Busy;
    if (offset > slot[spare()].size()) return Status::Error;
    slot[spare()].resize(offset);
    open = true;
    ++resumes;
    return Status::Ok;
  }
  bool write(const uint8_t* data, size_t len) override {
    if (!open || failWrites || slot[spare()].size() + len > capacity) return false;
    slot[spare()].insert(slot[spare()].end(), data, data + len);
    return true;
  }
  Status finish() override {
    if (!open) return Status::Error;
    open = false;
    const std::vector<uint8_t>& img = slot[spare()];
    return (!img.empty() && img[0] == 0xE9 && !forceInvalid) ? Status::Ok : Status::Invalid;
  }
  void abort() override { open = false; }
  bool read(size_t offset, uint8_t* out, size_t len) override {
    const std::vector<uint8_t>& img = slot[spare()];
    if (offset + len > img.size()) return false;
    memcpy(out, img.data() + offset, len);
    return true;
  }
  bool setBoot() override {
    if (failSetBoot) return false;
    boot = spare();
    state[boot] = SlotState::New;
    return true;
  }

  // ---- the bootloader and the running firmware's rollback calls ----
  int spare() const { return 1 - running; }
  // A restart: picks the slot to run (open writes are lost).
  void bootloader() {
    open = false;
    if (state[boot] == SlotState::New) {
      state[boot] = SlotState::PendingVerify;
    } else if (state[boot] == SlotState::PendingVerify) {
      state[boot] = SlotState::Aborted;  // never confirmed: roll back
      boot = 1 - boot;
    }
    running = boot;
  }
  bool pendingVerify() const { return state[running] == SlotState::PendingVerify; }
  void confirm() { state[running] = SlotState::Valid; }         // esp_ota_mark_app_valid_cancel_rollback
  void markInvalid() {                                           // ..._invalid_rollback_and_reboot (before the restart)
    state[running] = SlotState::Invalid;
    boot = 1 - running;
  }
  bool rolledBack() const {
    for (SlotState st : state) {
      if (st == SlotState::Aborted || st == SlotState::Invalid) return true;
    }
    return false;
  }

  size_t capacity = 0x140000;
  std::vector<uint8_t> slot[2];
  SlotState state[2] = {SlotState::Valid, SlotState::Valid};
  int running = 0;
  int boot = 0;
  bool open = false;
  bool failWrites = false;
  bool failBegin = false;
  bool failSetBoot = false;
  bool forceInvalid = false;
  int begins = 0;
  int resumes = 0;
};

// Bundles a controller with its fakes. The universal firmware's boot path
// picks the profile: a new light built with `buildDefault`'s type (default
// RGBW); profiles::kNone is a build without a default (setup-needed mode).
struct Rig {
  MockKv system;  // the fixture type ("fx")
  const FixtureProfile& fixture;
  MockKv kv;
  Stats stats;
  StateStore store{kv, stats, fixture};
  FakeEnv env;
  ControllerCore core{env, store, system, stats, fixture};
  uint32_t now = 1000;

  explicit Rig(const FixtureProfile& buildDefault = profiles::kRgbw)
      : fixture(fxselect::select(system, buildDefault.type)) {
    core.begin(now);
    env.clear();
  }
  void send(const char* line) { core.handleLine(line, now); }
  void advance(uint32_t ms) {
    for (uint32_t t = 0; t < ms; t += 50) {
      now += 50;
      core.tick(now);
    }
  }
};
