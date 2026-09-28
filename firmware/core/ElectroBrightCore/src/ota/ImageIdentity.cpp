#include "ImageIdentity.h"

#include <string.h>

#include "../config/Config.h"

namespace {

constexpr ImageIdentity makeIdentity() {
  ImageIdentity id{};
  for (size_t i = 0; i < sizeof(id.magic); ++i) id.magic[i] = imageid::kMagic[i];
  for (size_t i = 0; imageid::kProduct[i] && i + 1 < sizeof(id.product); ++i) id.product[i] = imageid::kProduct[i];
  for (size_t i = 0; imageid::kKind[i] && i + 1 < sizeof(id.kind); ++i) id.kind[i] = imageid::kKind[i];
  for (size_t i = 0; cfg::kFirmwareVersion[i] && i + 1 < sizeof(id.version); ++i) {
    id.version[i] = cfg::kFirmwareVersion[i];
  }
  return id;
}

#ifdef ESP_PLATFORM
#define EB_IDENTITY_SECTION __attribute__((section(".rodata_custom_desc"), used))
#else
#define EB_IDENTITY_SECTION
#endif

const ImageIdentity kIdentity EB_IDENTITY_SECTION = makeIdentity();

// A fixed-size text field: NUL-terminated within its size.
bool fieldEquals(const char* field, size_t size, const char* text) {
  const size_t n = strlen(text);
  return n < size && memcmp(field, text, n) == 0 && field[n] == '\0';
}

bool terminated(const char* field, size_t size) { return memchr(field, '\0', size) != nullptr; }

}  // namespace

namespace imageid {

const ImageIdentity& running() { return kIdentity; }

bool find(const uint8_t* image, size_t len, ImageIdentity& out) {
  const size_t end = len < kSearchBytes ? len : kSearchBytes;
  for (size_t off = 0; off + sizeof(ImageIdentity) <= end; off += 4) {
    if (memcmp(image + off, kMagic, sizeof(kMagic)) == 0) {
      memcpy(&out, image + off, sizeof(out));
      return true;
    }
  }
  return false;
}

bool isUniversal(const ImageIdentity& id) {
  FirmwareVersion v;
  return memcmp(id.magic, kMagic, sizeof(kMagic)) == 0 && fieldEquals(id.product, sizeof(id.product), kProduct) &&
         fieldEquals(id.kind, sizeof(id.kind), kKind) && terminated(id.version, sizeof(id.version)) &&
         parseVersion(id.version, v);
}

bool parseVersion(const char* text, FirmwareVersion& out) {
  uint32_t parts[3] = {0, 0, 0};
  int part = 0;
  bool digit = false;
  for (const char* p = text;; ++p) {
    if (*p >= '0' && *p <= '9') {
      parts[part] = parts[part] * 10u + static_cast<uint32_t>(*p - '0');
      if (parts[part] > 65535u) return false;
      digit = true;
    } else if ((*p == '.' || *p == '\0') && digit) {
      if (*p == '\0') break;
      if (++part > 2) return false;
      digit = false;
    } else {
      return false;
    }
  }
  if (part != 2) return false;
  out = {static_cast<uint16_t>(parts[0]), static_cast<uint16_t>(parts[1]), static_cast<uint16_t>(parts[2])};
  return true;
}

int compare(const FirmwareVersion& a, const FirmwareVersion& b) {
  if (a.major != b.major) return a.major < b.major ? -1 : 1;
  if (a.minor != b.minor) return a.minor < b.minor ? -1 : 1;
  if (a.patch != b.patch) return a.patch < b.patch ? -1 : 1;
  return 0;
}

}  // namespace imageid
