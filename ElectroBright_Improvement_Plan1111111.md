# ElectroBright — Verified Improvement Plan & Execution Instructions

**Audience:** the coding agent that will implement changes to `ElectroBright_ESP32C3_BLE.ino` and the `electrobright_app` Flutter project.

**Before you write a single line of code, read this entire document.** It supersedes the earlier `analysis_report.md` in two respects: it corrects a factual error in that report, and it adds a bug the report did not catch. Do not assume the report's conclusions are correct just because they sound confident — verify everything in Tier 0 yourself before acting.

---

## 0. Ground rules (apply to every tier)

1. **Work in a new git branch per tier** (e.g. `tier0-bugfix`, `tier1-app-hardening`, `tier2-fw-hardening`, `tier3-fw-split`, `tier4-binary-protocol`). Never mix tiers in one branch or one commit.
2. **Before writing code for a tier, write a short implementation plan** (as a markdown block or file) covering: exactly which files you'll touch, exactly what will change in each, what could break, and how you'll verify it didn't. Post/save this plan and treat it as a checkpoint — do not start editing until the plan is in place.
3. **After a tier's code changes, run the full test suite** (`flutter test` for the app) and, for firmware changes, do a full compile check. Report pass/fail counts explicitly. Do not report a tier as "done" without this.
4. **Never modify `SystemState` struct layout, field order, or the EEPROM magic-byte version in place.** If a firmware change requires new persisted fields, add a new `SystemStateV_next` struct and a new migration branch in `loadStateFromEEPROM()`, following the existing V5→V9 pattern exactly. Silently changing the packed struct will corrupt or wipe every already-deployed device's saved presets.
5. **Never change the wire protocol's existing command/response text format** unless you are explicitly executing Tier 4, and even then only additively (see Tier 4 rules). Both sides (firmware and app) must always be able to interoperate with the *other's* currently-shipped version.
6. **One tier at a time.** Get confirmation that a tier's tests pass before starting the next tier. Do not batch multiple tiers into one work session even if it seems more efficient — the point of tiers is to isolate blast radius.

---

## Tier 0 — Verify baseline & fix the confirmed bug (do this first, no exceptions)

**Goal:** establish ground truth about what currently works, and fix one real, verified bug before anything else touches this code.

### 0.1 Establish a real baseline
- Run `flutter test` on the app as-is and record the actual pass/fail output. Do not rely on the analysis report's claim that "there are currently no automated Unit Tests" — that claim is false; 5 test files exist (`ble_protocol_test.dart`, `device_notifier_test.dart`, `preset_execution_test.dart`, `color_picker_responsiveness_test.dart`, `widget_test.dart`). Find out which of them actually pass right now.

### 0.2 Fix the STATUS-format mismatch bug
**The bug:** In `test/device_notifier_test.dart`, two test cases (`"Loading factory preset updates entire app UI state immediately without hardware"` and `"Echo Suppression - Releasing lock accepts next broadcast"`) call:
```dart
transport.simulateIncomingNotification('STATUS:MODE=1;SPEED=5;FREQ=5;R=10;G=10;B=10;W=10;BR=255;FWC=0;CC=0;PC=1');
```
This is a semicolon-delimited `KEY=value` format. But the **real firmware** (`sendStatus()` in the `.ino`) sends, and the **real parser** (`BleProtocol.parseStatus` in `lib/core/ble/ble_protocol.dart`) expects, a **positional comma-separated** format:
```
STATUS:<r>,<g>,<b>,<w>,<brightness>,<mode>,<speed>,<freq>,<fwc>,<cc>,<pc>,<sleep>,<timerActive>,<timerRemainingSec>,<soundEnabled>
```
Because the test string has no commas, `data.split(',')` yields a single-element list, `parts.length < 11`, and `parseStatus` returns `null`. The notifier's `_handleIncomingNotification` then does nothing — meaning the "echo suppression accepts the broadcast" assertions that follow (`expect(notifier.state.red, 10)` etc.) are checking behavior that the real parser never triggers. This is almost certainly a stale fixture from before the protocol was standardized to CSV, never updated.

**What to do:**
1. Rewrite both test fixtures to use the real CSV format that matches what `sendStatus()` actually emits (verify field order and count against the current `.ino`, not from memory).
2. Re-run the test and confirm it now genuinely exercises the echo-suppression logic (i.e., confirm it would fail if you temporarily broke `EchoSuppressor.isLocked` logic — a quick sanity check, then revert).
3. Add one new focused test in `ble_protocol_test.dart` that feeds `BleProtocol.parseStatus` the *exact* string format `sendStatus()` produces (all 15 fields), so a future protocol drift on either side gets caught immediately instead of silently no-op'ing.
4. Do not touch anything else in this tier.

### 0.3 Deliverable for Tier 0
- A single small commit/PR: corrected test fixtures + one new regression test.
- Full `flutter test` output showing everything passing.

---

## Tier 1 — Low-risk Flutter app improvements (independent of firmware)

Only start after Tier 0 is merged and green.

1. **Persistent app state.** `shared_preferences` is already a dependency (used in tests). Persist: last-connected device ID, and `activePresetId`. Restore on app start in the relevant notifier(s) (`connection_notifier.dart`, `device_notifier.dart`). Write a plan for exactly which fields get persisted and when they're written (avoid writing on every slider tick — debounce, similar in spirit to the firmware's own EEPROM coalescing).
2. **Reconnect logic.** Add bounded, backed-off automatic reconnection in `physical_ble_transport.dart` / `connection_notifier.dart` for the case where the device drops out of BLE range and comes back. Cap retry attempts/backoff so it can't infinite-loop or drain battery; surface connection state to the UI so it's not silently retrying forever with no feedback.
3. **Test coverage for the above.** Add tests using `MockBleTransport` for the new persistence and reconnect behavior specifically — extend the existing test patterns rather than inventing a new style.

### Deliverable for Tier 1
Plan → code → `flutter test` green → short summary of what changed and what new tests cover it.

---

## Tier 2 — Firmware hardening, *no protocol or struct changes*

Only start after Tier 1 is merged and the app is stable.

1. **Reduce `String` heap churn.** The `.ino` uses Arduino `String` ~48 times. On an ESP32-C3 running for extended periods, repeated `String` concat/allocation risks heap fragmentation over long uptimes. Where a `char buf[]` + `snprintf` is already built (e.g. `sendStatus`, `sendPresetList`, `MODE_SETTINGS` handler), avoid wrapping the result in `String(buf)` just to hand it to `bleSendString` — add a `bleSendString(const char*)` overload that calls `pTxCharacteristic->setValue((uint8_t*)str, len); notify();` directly, and use it at those call sites. Do **not** change what bytes go out over BLE — only how they're assembled in memory.
2. Compile-check after every change (this is Arduino/C++; a single typo won't be caught until compile). If you don't have access to a compiler/toolchain in this environment, say so explicitly and flag the change as unverified rather than claiming it's tested.
3. Leave `delay(500)` in the disconnect-handling branch alone unless you've confirmed (from BLE stack docs, not assumption) that it's unnecessary — it's a one-time reconnect-advertising delay, not a hot-path blocker, and "no `delay()` in the codebase" is not actually true today (there are two, both justified) — don't let a review that says "fully non-blocking" push you into removing something correct.

### Deliverable for Tier 2
Plan → code → note that no wire format or EEPROM layout changed → confirmation of successful compile (or explicit note that compile could not be verified in this environment).

---

## Tier 3 — Firmware file splitting (`.ino` → `.h`/`.cpp` modules)

Only start after Tier 2 is merged. This is a **structural**, not behavioral, refactor — the goal is that the compiled binary's behavior is byte-for-byte identical.

1. Propose the module boundaries in your plan before moving code. A reasonable split (adjust if the actual code suggests otherwise):
   - `BleProtocol.h/.cpp` — command parsing (`parseCommand`, `parseValuesStrict`, `atoiStrict`), BLE server/characteristic setup, `bleSendString`.
   - `LedController.h/.cpp` — `applyLEDs`, all `mode*()` effect functions, `updateEffects`, `hsv2rgb`.
   - `Storage.h/.cpp` — `SystemState` and all versioned structs, `loadStateFromEEPROM`, `updateEEPROM`, `savePreset`/`loadPreset`/`deletePreset`, `factoryReset`, CRC calculation.
   - Leave `setup()`, `loop()`, pin/status-LED/buzzer/timer glue in the main `.ino`.
2. Move **one module at a time**, in its own commit, and compile after each move before starting the next. Do not move all three modules in one shot.
3. Pay close attention to global state shared across modules (`currentState`, `cmdQueue`, `currentMillis`, dirty flags) — these need `extern` declarations in headers, not duplicated definitions.
4. After all moves, do a full diff-review confirming no logic changed, only location.

### Deliverable for Tier 3
Plan (with proposed module boundaries) → one commit per module → confirmation of successful compile after each → final note confirming no protocol/EEPROM/behavior changes were introduced.

---

## Tier 4 — Protocol optimization (binary payload) — optional, highest risk, do last

**Only undertake this tier if explicitly requested after seeing Tiers 0–3 land successfully.** Reasoning for the caution:

- This is the only tier that requires firmware and app to change **in coordination**, and real hardware in the field may be running old firmware paired with a newly-updated app, or vice versa. A naive "switch everything to binary" breaks that hardware silently.
- The actual bottleneck for a lighting-control app is more likely the BLE connection interval and notification throughput than ASCII parsing overhead — verify with real measurements (packet timing during a slider drag) before assuming binary framing is the fix. Don't optimize based on the report's assertion alone.
- ASCII protocol has real debugging value (you can talk to the device with any BLE terminal app) — don't discard that for the entire protocol.

**If you proceed, do it additively and safely:**
1. Keep the existing ASCII command set as the default and permanent fallback. Never remove it.
2. Add version negotiation: the app already calls `getVersion()` on connect (`VERSION:x.y.z`). Use this to detect firmware that supports a new binary fast-path; if the firmware doesn't report a high-enough version, the app must keep using ASCII, full stop.
3. Scope the binary path narrowly — only to the highest-frequency continuous commands (`RGBW`, `BRIGHTNESS` during slider drag), not to mode/preset/timer commands where bandwidth was never the bottleneck.
4. Increment the firmware `VERSION` string and add a new `EEPROM_MAGIC_BYTE` generation only if the binary work requires new persisted fields — otherwise leave storage untouched.
5. Write dedicated tests (`ble_protocol_test.dart`-style) for the binary encode/decode path with the same rigor as Tier 0's fix — a mismatched binary framing bug is much harder to spot by eye than an ASCII one.

### Deliverable for Tier 4
A written negotiation/compatibility plan reviewed and approved *before* any code, then implementation, then explicit tests proving old-firmware + new-app and new-firmware + old-app both still work over ASCII.

---

## Explicitly out of scope for this pass

**OTA updates** (mentioned in the original report) are a separate, substantial project — partition layout, update signing/verification, rollback safety — and should not be bundled into this improvement pass. If wanted later, it deserves its own design document and its own tier sequence, starting from a stable Tier 3 firmware baseline.

---

## Summary checklist for the agent

- [ ] Tier 0: fix the verified STATUS-format test bug + establish real baseline — **do this before anything else**
- [ ] Tier 1: app persistence + reconnect logic + tests
- [ ] Tier 2: firmware `String` reduction, no protocol/struct changes
- [ ] Tier 3: firmware file split into modules, behavior-identical
- [ ] Tier 4 (optional, only if requested): binary protocol fast-path, backward-compatible
- [ ] OTA: separate project, not part of this plan

For every tier: **plan → confirm → implement → test → report results** before moving on.
