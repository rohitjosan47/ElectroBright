#pragma once
// The flash side of a wireless update: the spare OTA app slot. ESP-IDF's OTA
// API on the device (platform/EspOtaFlash), an in-memory fake in the host tests.

#include <stddef.h>
#include <stdint.h>

class IOtaFlash {
 public:
  enum class Status : uint8_t {
    Ok,
    Busy,     // the running firmware is not confirmed yet (rollback pending)
    Invalid,  // pollFinish(): not a valid app image
    Error,    // flash failure
    Pending,  // pollFinish(): the image is still being verified
  };

  virtual ~IOtaFlash() = default;

  // Capacity of the slot an update goes to (0: no spare slot).
  virtual size_t spareSize() = 0;
  // Capacity of the slot this firmware runs from.
  virtual size_t runningSize() = 0;
  // Starts writing at offset 0 (sequential writes: each sector is erased as the
  // data reaches it, never the whole slot at once).
  virtual Status begin() = 0;
  // Continues a transfer of this boot whose first `offset` bytes are written.
  virtual Status resume(size_t offset) = 0;
  virtual bool write(const uint8_t* data, size_t len) = 0;
  // Ends the writing and starts validating the image (esp_ota_end), off the
  // caller's task: that can take longer than the task watchdog allows.
  // Ok: started (the write is closed either way).
  virtual Status startFinish() = 0;
  // Pending while the validation runs, then its result (Ok, Invalid, Error),
  // once; afterwards Error until the next startFinish().
  virtual Status pollFinish() = 0;
  // Drops an open write; what is on flash stays (resume() may continue it).
  virtual void abort() = 0;
  virtual bool read(size_t offset, uint8_t* out, size_t len) = 0;
  // Boots the spare slot on the next restart.
  virtual bool setBoot() = 0;
};
