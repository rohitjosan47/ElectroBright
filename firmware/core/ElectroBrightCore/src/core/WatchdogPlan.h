#pragma once
// How the firmware sets up the task watchdog (TWDT), portable so the host
// tests check it (platform/App.cpp applies it).
//
// The ESP-IDF startup of the Arduino core (CONFIG_ESP_TASK_WDT_INIT=1 in core
// 3.3.11 and 3.3.12) has already initialised the TWDT with its own settings
// (5 s) before the firmware runs, and esp_task_wdt_init() would then log
// "TWDT already initialized" and refuse. The firmware reconfigures it instead:
// its own timeout, a panic (and so a restart) on timeout, and every core's idle
// task watched. The control and render tasks subscribe themselves.
//
// A restart before a freshly updated firmware has confirmed itself makes the
// bootloader return to the previous one, so a frozen update rolls back.

#include <stdint.h>

#include "../config/Config.h"
#include "../ota/SelfCheck.h"

namespace wdtplan {

struct Plan {
  bool reconfigure;       // the TWDT is already running: esp_task_wdt_reconfigure, not _init
  uint32_t timeoutMs;
  uint32_t idleCoreMask;  // idle tasks watched too (catches CPU starvation)
  bool panicOnTimeout;    // a timeout panics, and the panic handler restarts the chip
};

constexpr Plan make(bool startedByCore, uint32_t cores) {
  return Plan{startedByCore, cfg::kWatchdogTimeoutMs, (1u << cores) - 1u, true};
}

// A frozen, unconfirmed update is reset long before its self-check deadline.
static_assert(cfg::kWatchdogTimeoutMs + selfcheck::kFreezeAfterMs < selfcheck::kDeadlineMs,
              "the watchdog must restart a frozen update before the self-check deadline");

}  // namespace wdtplan
