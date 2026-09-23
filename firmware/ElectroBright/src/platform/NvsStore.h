#pragma once
// IKeyValueStore on ESP-IDF NVS (wear-levelled, CRC-protected, atomic per key).

#include <nvs.h>

#include "../state/KeyValueStore.h"

class NvsStore final : public IKeyValueStore {
 public:
  bool begin(const char* nameSpace);

  bool read(const char* key, void* out, size_t len) override;
  bool write(const char* key, const void* data, size_t len) override;
  bool erase(const char* key) override;
  bool eraseAll() override;

  // Deletes every key of another namespace (used once for the old firmware's
  // "eeprom" data — this firmware starts clean, no migration).
  static void wipeNamespace(const char* nameSpace);

 private:
  nvs_handle_t handle_ = 0;
  bool open_ = false;
};
