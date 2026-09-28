#include "EspOtaFlash.h"

#include <esp_partition.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "../config/Config.h"

const esp_partition_t* EspOtaFlash::spare() { return esp_ota_get_next_update_partition(nullptr); }

size_t EspOtaFlash::spareSize() {
  const esp_partition_t* p = spare();
  return p ? p->size : 0;
}

size_t EspOtaFlash::runningSize() {
  const esp_partition_t* p = esp_ota_get_running_partition();
  return p ? p->size : 0;
}

IOtaFlash::Status EspOtaFlash::begin() {
  abort();
  const esp_partition_t* p = spare();
  if (p == nullptr) return Status::Error;
  const esp_err_t err = esp_ota_begin(p, OTA_WITH_SEQUENTIAL_WRITES, &handle_);
  if (err == ESP_ERR_OTA_ROLLBACK_INVALID_STATE) return Status::Busy;
  if (err != ESP_OK) return Status::Error;
  open_ = true;
  return Status::Ok;
}

IOtaFlash::Status EspOtaFlash::resume(size_t offset) {
  abort();
  const esp_partition_t* p = spare();
  if (p == nullptr) return Status::Error;
  const esp_err_t err = esp_ota_resume(p, OTA_WITH_SEQUENTIAL_WRITES, offset, &handle_);
  if (err == ESP_ERR_OTA_ROLLBACK_INVALID_STATE) return Status::Busy;
  if (err != ESP_OK) return Status::Error;
  open_ = true;
  return Status::Ok;
}

bool EspOtaFlash::write(const uint8_t* data, size_t len) {
  return open_ && esp_ota_write(handle_, data, len) == ESP_OK;
}

IOtaFlash::Status EspOtaFlash::startFinish() {
  if (!open_ || finish_.load() == Status::Pending) return Status::Error;
  open_ = false;  // esp_ota_end frees the handle whatever the result
  finish_ = Status::Pending;
  if (xTaskCreate(verifyTask, "eb-verify", cfg::kVerifyStackBytes, this, tskIDLE_PRIORITY, nullptr) != pdPASS) {
    esp_ota_abort(handle_);
    finish_ = Status::Error;
    return Status::Error;
  }
  return Status::Ok;
}

void EspOtaFlash::verifyTask(void* arg) {
  EspOtaFlash* self = static_cast<EspOtaFlash*>(arg);
  const esp_err_t err = esp_ota_end(self->handle_);
  self->finish_ = err == ESP_OK ? Status::Ok : err == ESP_ERR_OTA_VALIDATE_FAILED ? Status::Invalid : Status::Error;
  vTaskDelete(nullptr);
}

IOtaFlash::Status EspOtaFlash::pollFinish() {
  const Status st = finish_.load();
  if (st != Status::Pending) finish_ = Status::Error;  // reported once
  return st;
}

void EspOtaFlash::abort() {
  if (!open_) return;
  open_ = false;
  esp_ota_abort(handle_);
}

bool EspOtaFlash::read(size_t offset, uint8_t* out, size_t len) {
  const esp_partition_t* p = spare();
  return p && esp_partition_read(p, offset, out, len) == ESP_OK;
}

bool EspOtaFlash::setBoot() {
  const esp_partition_t* p = spare();
  return p && esp_ota_set_boot_partition(p) == ESP_OK;
}

uint32_t EspOtaFlash::runningSlot() {
  const esp_partition_t* p = esp_ota_get_running_partition();
  if (p == nullptr || p->subtype < ESP_PARTITION_SUBTYPE_APP_OTA_MIN || p->subtype > ESP_PARTITION_SUBTYPE_APP_OTA_MAX) {
    return 0;
  }
  return static_cast<uint32_t>(p->subtype - ESP_PARTITION_SUBTYPE_APP_OTA_MIN);
}

bool EspOtaFlash::lastUpdateRolledBack() {
  // The bootloader marks a slot that never confirmed itself ABORTED (or the
  // firmware marks it INVALID) and returns to the other one.
  return esp_ota_get_last_invalid_partition() != nullptr;
}

bool EspOtaFlash::pendingVerify() {
  esp_ota_img_states_t st;
  const esp_partition_t* p = esp_ota_get_running_partition();
  return p && esp_ota_get_state_partition(p, &st) == ESP_OK && st == ESP_OTA_IMG_PENDING_VERIFY;
}
