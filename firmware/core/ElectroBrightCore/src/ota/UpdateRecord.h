#pragma once
// What the last update's finish took (END received to END_OK sent: the
// image verification of esp_ota_end, the identity check and the boot switch),
// kept in the system namespace (cfg::kSystemNvsNamespace) across the restart
// into the new firmware, which reports it as DIAG endms=.

#include <stdint.h>

#include "../state/KeyValueStore.h"

namespace updaterecord {

constexpr const char* kFinishKey = "oend";

inline bool writeFinishMs(IKeyValueStore& system, uint32_t ms) { return system.write(kFinishKey, &ms, sizeof(ms)); }

// 0 when none is recorded.
inline uint32_t readFinishMs(IKeyValueStore& system) {
  uint32_t ms = 0;
  return system.read(kFinishKey, &ms, sizeof(ms)) ? ms : 0;
}

}  // namespace updaterecord
