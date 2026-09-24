#pragma once
// Host-side fakes for the platform interfaces.

#include <map>
#include <string>
#include <vector>

#include "control/ControllerCore.h"
#include "state/KeyValueStore.h"
#include "ElectroBright_RGBW/Fixture.h"

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
    if (failWrites) return false;
    data.erase(key);
    return true;
  }
  bool eraseAll() override {
    if (failWrites) return false;
    data.clear();
    return true;
  }

  std::map<std::string, std::vector<uint8_t>> data;
  int writes = 0;
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

  std::string last() const { return lines.empty() ? std::string() : lines.back(); }
  void clear() {
    lines.clear();
    sounds.clear();
  }

  std::vector<std::string> lines;
  std::vector<SoundId> sounds;
  RenderParams params{};
  int publishes = 0;
};

// Bundles a controller with its fakes.
struct Rig {
  MockKv kv;
  Stats stats;
  StateStore store{kv, stats, fx::rgbw::kProfile};
  FakeEnv env;
  ControllerCore core{env, store, stats, fx::rgbw::kProfile};
  uint32_t now = 1000;

  Rig() { core.begin(now); env.clear(); }
  void send(const char* line) { core.handleLine(line, now); }
  void advance(uint32_t ms) {
    for (uint32_t t = 0; t < ms; t += 50) {
      now += 50;
      core.tick(now);
    }
  }
};
