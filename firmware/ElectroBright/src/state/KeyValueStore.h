#pragma once
// Minimal key/value blob storage interface. Implemented by NVS on the device
// (platform/NvsStore) and by an in-memory mock in the host tests.

#include <stddef.h>

class IKeyValueStore {
 public:
  virtual ~IKeyValueStore() = default;

  // True only if `key` exists AND holds exactly `len` bytes.
  virtual bool read(const char* key, void* out, size_t len) = 0;
  // Writes and commits atomically. False on any failure.
  virtual bool write(const char* key, const void* data, size_t len) = 0;
  // Removes a key; true if it is gone afterwards (also when it never existed).
  virtual bool erase(const char* key) = 0;
  // Removes every key in the namespace.
  virtual bool eraseAll() = 0;
};
