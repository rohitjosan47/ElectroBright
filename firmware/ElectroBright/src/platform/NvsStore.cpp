#include "NvsStore.h"

#include <nvs_flash.h>

bool NvsStore::begin(const char* nameSpace) {
  esp_err_t err = nvs_flash_init();  // no-op if the core already initialised it
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    err = nvs_flash_init();
  }
  if (err != ESP_OK) return false;
  open_ = nvs_open(nameSpace, NVS_READWRITE, &handle_) == ESP_OK;
  return open_;
}

bool NvsStore::read(const char* key, void* out, size_t len) {
  if (!open_) return false;
  size_t size = 0;
  if (nvs_get_blob(handle_, key, nullptr, &size) != ESP_OK || size != len) return false;
  return nvs_get_blob(handle_, key, out, &size) == ESP_OK;
}

bool NvsStore::write(const char* key, const void* data, size_t len) {
  if (!open_) return false;
  if (nvs_set_blob(handle_, key, data, len) != ESP_OK) return false;
  return nvs_commit(handle_) == ESP_OK;
}

bool NvsStore::erase(const char* key) {
  if (!open_) return false;
  const esp_err_t err = nvs_erase_key(handle_, key);
  if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) return false;
  return nvs_commit(handle_) == ESP_OK;
}

bool NvsStore::eraseAll() {
  if (!open_) return false;
  if (nvs_erase_all(handle_) != ESP_OK) return false;
  return nvs_commit(handle_) == ESP_OK;
}

void NvsStore::wipeNamespace(const char* nameSpace) {
  nvs_handle_t h;
  // Opening read-only fails with NOT_FOUND when the namespace never existed,
  // so a fresh device does no flash writes here.
  if (nvs_open(nameSpace, NVS_READONLY, &h) != ESP_OK) return;
  nvs_close(h);
  if (nvs_open(nameSpace, NVS_READWRITE, &h) != ESP_OK) return;
  nvs_erase_all(h);
  nvs_commit(h);
  nvs_close(h);
}
