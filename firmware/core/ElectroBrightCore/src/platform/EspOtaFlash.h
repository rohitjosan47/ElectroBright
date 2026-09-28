#pragma once
// IOtaFlash on ESP-IDF's OTA API: the spare app slot (esp_ota_get_next_update_partition).
// Writes are sequential (OTA_WITH_SEQUENTIAL_WRITES): each 4 KB sector is
// erased when the data reaches it, so no call blocks for long and BLE keeps
// running. Nothing touches the boot selection until setBoot().

#include <esp_ota_ops.h>

#include "../ota/OtaFlash.h"

class EspOtaFlash final : public IOtaFlash {
 public:
  size_t spareSize() override;
  Status begin() override;
  Status resume(size_t offset) override;
  bool write(const uint8_t* data, size_t len) override;
  Status finish() override;
  void abort() override;
  bool read(size_t offset, uint8_t* out, size_t len) override;
  bool setBoot() override;

  // Rollback bookkeeping for DIAG and the first-boot check.
  static uint32_t runningSlot();
  static bool lastUpdateRolledBack();
  static bool pendingVerify();  // this firmware still has to confirm itself

 private:
  const esp_partition_t* spare();

  esp_ota_handle_t handle_ = 0;
  bool open_ = false;
};
