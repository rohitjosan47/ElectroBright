#pragma once
// IOtaFlash on ESP-IDF's OTA API: the spare app slot (esp_ota_get_next_update_partition).
// Writes are sequential (OTA_WITH_SEQUENTIAL_WRITES): each 4 KB sector is
// erased when the data reaches it, so no call blocks for long and BLE keeps
// running. Nothing touches the boot selection until setBoot().
//
// startFinish() runs esp_ota_end, which reads the whole image back to verify
// it, on a short-lived task at idle priority that the task watchdog does not
// watch: however long it takes, the control and render tasks keep running
// (and feeding the watchdog), and the idle task shares the CPU with it, so its
// watchdog is fed too.

#include <esp_ota_ops.h>

#include <atomic>

#include "../ota/OtaFlash.h"

class EspOtaFlash final : public IOtaFlash {
 public:
  size_t spareSize() override;
  size_t runningSize() override;
  Status begin() override;
  Status resume(size_t offset) override;
  bool write(const uint8_t* data, size_t len) override;
  Status startFinish() override;
  Status pollFinish() override;
  void abort() override;
  bool read(size_t offset, uint8_t* out, size_t len) override;
  bool setBoot() override;

  // Rollback bookkeeping for DIAG and the first-boot check.
  static uint32_t runningSlot();
  // A slot is marked invalid (aborted): a rollback has happened since that
  // slot was last written (the next update's BEGIN clears it).
  static bool lastUpdateRolledBack();
  static bool pendingVerify();  // this firmware still has to confirm itself

 private:
  const esp_partition_t* spare();
  static void verifyTask(void* self);

  esp_ota_handle_t handle_ = 0;
  bool open_ = false;
  // pollFinish(): Pending while verifyTask runs, then its result; Error when idle.
  std::atomic<Status> finish_{Status::Error};
};
