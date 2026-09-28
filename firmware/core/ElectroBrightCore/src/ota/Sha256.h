#pragma once
// SHA-256 (FIPS 180-4), portable and allocation-free: the OTA receiver hashes
// the image as it arrives, so END can compare it with the hash from BEGIN.

#include <stddef.h>
#include <stdint.h>

class Sha256 {
 public:
  static constexpr size_t kDigestSize = 32;

  Sha256() { reset(); }
  void reset();
  void update(const uint8_t* data, size_t len);
  // The digest of everything so far; the running state is left untouched
  // (update() may continue afterwards).
  void digest(uint8_t out[kDigestSize]) const;

 private:
  void block(const uint8_t* p);

  uint32_t h_[8];
  uint64_t bytes_;
  uint8_t buf_[64];
  size_t used_;
};
