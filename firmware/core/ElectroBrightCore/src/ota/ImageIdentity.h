#pragma once
// The identity block every ElectroBright firmware image carries, so a light
// can tell, before switching its boot partition, that a received image is an
// ElectroBright universal image of the announced version.
//
// On the device the block sits in section .rodata_custom_desc, which the
// ESP-IDF linker script places right after the app descriptor at the start of
// the image (image offset 0x120 on the ESP32-C3). The receiver does not rely
// on the exact offset: it scans the image head for the magic.

#include <stddef.h>
#include <stdint.h>

struct ImageIdentity {
  char magic[8];     // "EBIMGID1" (no terminator)
  char product[16];  // "ElectroBright"
  char kind[12];     // "universal": every type in one image, the light keeps its own
  char version[16];  // "3.8.1"
  uint8_t rollbackTest;  // cfg::kRollbackTest: 0, or a rollback test image (1 fails its check, 2 freezes)
  uint8_t reserved[11];
};
static_assert(sizeof(ImageIdentity) == 64, "the identity block is 64 bytes");

struct FirmwareVersion {
  uint16_t major, minor, patch;
};

namespace imageid {

constexpr char kMagic[8] = {'E', 'B', 'I', 'M', 'G', 'I', 'D', '1'};
constexpr const char* kProduct = "ElectroBright";
constexpr const char* kKind = "universal";
// How far into an image the block is looked for.
constexpr size_t kSearchBytes = 1024;

// This firmware's own block (kept in the image by the reference in running()).
const ImageIdentity& running();

// Finds the block in the first bytes of an image (4-byte aligned). False when
// there is none.
bool find(const uint8_t* image, size_t len, ImageIdentity& out);

// True when the block names an ElectroBright universal image with a valid version.
bool isUniversal(const ImageIdentity& id);

// "3.8.1" -> {3, 8, 1}; false for anything else.
bool parseVersion(const char* text, FirmwareVersion& out);
int compare(const FirmwareVersion& a, const FirmwareVersion& b);

}  // namespace imageid
