# ElectroBright Firmware (ESP32-C3)

Firmware for the ElectroBright RGBW light controller. It was written from scratch as a replacement for the original firmware. It is compatible with the Flutter app in `electrobright_app/` and with the hardware in [`docs/wiring_guide.md`](../../docs/wiring_guide.md).

Firmware version: **3.4.0** · Model id: **EB-C3-RGBW-V1** · BLE name: **ElectroBright_C3_V1**

---

## 1. Build & flash

| Item | Requirement (verified) |
|---|---|
| IDE | Arduino IDE 2.x |
| Board package | **esp32 by Espressif ≥ 3.0** (verified with 3.3.11) |
| Library | **NimBLE-Arduino 2.x** by h2zero (verified with 2.5.1) — install via Library Manager |
| Board | **ESP32C3 Dev Module** (`esp32:esp32:esp32c3`) |
| USB CDC On Boot | Enabled (only needed for serial logs) |

1. **File → Open…** `firmware/ElectroBright/ElectroBright.ino`
2. Select the board and port, then **Upload**.

Reference build (v3.4.0): 653 KB flash (49 %), 30.8 KB static RAM (9 %), zero compiler
warnings with `--warnings all`.

Command line (the Arduino IDE ships `arduino-cli`):
```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc --warnings all firmware/ElectroBright
```

**First boot starts clean.** Settings and presets saved by the original
firmware (NVS namespace `eeprom`) are erased once; nothing is migrated. The light comes
up white at full brightness with no presets.

---

## 2. Architecture

```
NimBLE host task ── write callback: validate + copy only ──► colour mailbox (latest wins)
                                                         └─► text stream buffer (1 KB)
                                                                  │ notify
CONTROL task (prio 6) ── the ONLY owner of device state (actor model)
   LineAssembler → CommandParser → ControllerCore → replies (Egress → BLE notify)
   StateStore (NVS, debounced) · sleep timer · sounds
                                                                  │ SeqLock snapshot
esp_timer 200 Hz ─► RENDER task (prio 10)
   RenderEngine: smoothing → effect (+ crossfade) → brightness → sleep fade → LEDC
   SoundSequencer tick → buzzer
```

Design rules that remove whole classes of bugs found in the original firmware:

- **No shared mutable state.** BLE callbacks never touch the state; only the
  control task mutates it; the render task reads an immutable snapshot through
  a non-blocking seqlock. There are no data races by construction.
- **Fixed-rate rendering.** Frames run at exactly 200 Hz from a hardware
  timer, never from a `loop()` with a variable `delay()`.
- **Everything smoothed in linear light.** Colour (τ 45 ms) and brightness
  (τ 70 ms) chase their targets, so 30 ms app packets become a continuous
  200 Hz sweep. Mode changes crossfade over 300 ms, and sleep/wake fade over
  400 ms (2 s for the timer).
- **Parameters apply on the next frame.** Effects keep time in phase
  accumulators or stored random factors, so moving a slider never restarts or
  jumps an animation.
- **No heap after init, no `String`.** All buffers are static and bounded, with
  explicit drop policies (DIAG counts every drop).
- **Defensive input.** Over-long or binary-garbage lines are discarded whole.
  Numbers are parsed strictly with exact field counts. Text writes enter the
  stream all-or-nothing. Binary frames are checksum-verified.
- **Watchdog.** The Task WDT (3 s, panic → reboot) covers the control, render
  and idle tasks.
- **Safe power-up.** The LED gates are driven low first, then the device
  fades in from black over 600 ms (no boot flash, no inrush spike).
- **Phase-shifted PWM.** The four channels switch at ¼-period offsets, which
  lowers the peak current on the strip supply and reduces EMI.

### Source map

| Path | Portable? | Purpose |
|---|---|---|
| `src/config/Config.h` | ✓ | Every pin, rate, timing and buffer size |
| `src/core/` | ✓ | Types, math, RNG, noise, seqlock, stats |
| `src/protocol/` | ✓ | Line assembler, parser, binary frames, reply formats, egress packing |
| `src/state/` | ✓ | Scene/settings schema, persistence policy |
| `src/control/ControllerCore.*` | ✓ | Command semantics, sleep timer, presets |
| `src/render/` | ✓ | Colour pipeline, render engine, mode registry, 13 effects |
| `src/feedback/` | ✓ | Buzzer melodies and sequencer |
| `src/platform/` | ESP32 | LEDC PWM, buzzer, NVS, NimBLE NUS, tasks/timer wiring |

"Portable" code has no Arduino / ESP-IDF includes (enforced by `make portable`)
and is fully covered by the host tests.

---

## 3. Modes and sliders

Protocol command names are unchanged (`SPEED:` / `FREQUENCY:`). The **UI
names** now describe what each slider really does (`src/render/ModeRegistry.h`
must match the app's `mode_definition.dart`; the app test
`mode_registry_sync_test.dart` enforces this).

| # | Mode | Speed slider | Frequency slider |
|---|---|---|---|
| 1 | Solid Color | — | — |
| 2 | Blink | — | **Blink Rate**: period 1.6 s → 120 ms |
| 3 | Breath | **Breath Shape**: soft sine → quick inhale, hold, long exhale | **Breathing Rate**: 8 s → 1 s per breath |
| 4 | Fireworks | **Burst Speed**: burst durations ×1.6 → ×0.5 | **Launch Rate**: 8 s → 0.8 s between shells |
| 5 | TV Simulator | **Scene Pace**: scenes 8 s → 1 s | **Cuts & Flicker**: 10 → 80 % hard cuts, more flicker |
| 6 | Thunderstorm | **Stroke Tempo**: typical gap between strokes 160 → 40 ms (irregular around it) | **Strike Rate**: 4 → 30 strikes per minute (15 s → 2 s, ±20 %) |
| 7 | Faulty Bulb | **Glitch Speed**: glitch durations ×1.5 → ×0.5 | **Glitch Rate**: 12 s → 1.5 s between glitches |
| 8 | Welding | **Weld Length**: 0.3 s tacks → 8 s beads | **Weld Gap**: 0.8 s → 12 s pause between welds |
| 9 | Club Lights | **Tempo**: 90 → 170 BPM | **Energy**: pattern density and strobe rate |
| 10 | Rainbow | — | **Cycle Speed**: 30 s → 3 s per hue cycle |
| 11 | Fire | **Flicker Speed**: noise time-scale ×0.4 → ×2.5 | **Flame Intensity**: 15 → 60 % depth and more flares |
| 12 | Police Strobe | **Flash Speed**: flash 150 → 40 ms | **Flashes per Side**: 1 → 6 |
| 13 | Candle | **Flicker Speed**: noise time-scale ×0.4 → ×2.5 | **Flicker Depth**: 4 → 35 % |

All ranges are geometric across 1..10, so every step feels like the same
relative change. Club Lights is never pitch black, except a rare (~5 % of
bars) accent blackout of at most 120 ms.

**Welding** mimics a real MIG/stick arc:
- 1–3 scratch-start sparks before the arc catches.
- A living arc:
  - plasma shimmer (~55 Hz);
  - short-circuit crackle dips;
  - spatter pops;
  - slow hand wander;
  - weaving on long beads.
- Occasional arc outages with a re-strike.
- Crater-fill re-arcs.
- A dim cooling-bead glow with hot-spatter twinkles after each weld.
- Short lengths sometimes become runs of 2–4 tack welds.
- Uses the picked colour.

**Thunderstorm** reproduces real lightning strike patterns, with controlled variety:
- **Every strike has one full-power bolt.**
- **Each strike is one of five real-world strike characters:**
  - **Crack:** one massive, sometimes split bolt, often with a late echo.
  - **Classic:** 3–5 strokes, the bolt first and then weaker, irregularly spaced aftershocks. Occasionally a later stroke is full-power again.
  - **Stutter:** 5–9 quick crackling strokes; the brightest hit may land mid-flash.
  - **Burner:** a few strokes, then a long wavering glow with sharp flare-ups (the continuing current, with M-components).
  - **BuildUp:** 2–4 cloud flickers that grow faster and brighter, then the bolt.
- **Characters come from a shuffle bag.** The mix is exact over every 10 strikes (2 / 3 / 2 / 2 / 1), and the same character never appears twice in a row.
- **Each stroke has a physical shape:** an instant spike plus a short dim afterglow. It is rendered frame-averaged, so timing and energy are exact even between frames.
- **The statistics match high-speed-video studies:**
  - ≈4.3 strokes per strike;
  - ~10 % single-stroke and ~25 % with 6+ strokes;
  - irregular, log-normal gaps between strokes;
  - later strokes ≈80 % of the bolt's perceived brightness;
  - ≈⅓ of strikes with a sustained glow.
- **Strike spacing** follows the Strike Rate, with only ±20 % natural variation.
- Completely dark between strikes.
- Uses the picked colour.

---

## 4. BLE protocol (Nordic UART Service)

Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX (write / write-no-response)
`…0002`, TX (notify) `…0003`. Text lines end with `\n`, `\r` or `\r\n`; names
are case-insensitive. Replies are `\n`-terminated. Several replies may share
one notification, and a long reply may span notifications.

**Binary colour fast path** (no reply), 8 bytes:
`[0xAA, seq, R, G, B, W, Brightness, seq^R^G^B^W^Br^0x55]`. The legacy 6- and
7-byte forms are also accepted.

| Command | Reply |
|---|---|
| `RGBW:r,g,b,w` (alias `COLOR:`) · `BRIGHTNESS:0-255` · `SPEED:1-10` · `FREQUENCY:1-10` | none (high-rate) |
| `MODE:1-13` · `MODE_SPEED:m,s` · `MODE_FREQUENCY:m,f` | `OK` |
| `FIREWORK_COLOR_MODE:0\|1` · `CLUB_COLOR_MODE:0\|1` · `POLICE_COLOR_MODE:0\|1` | `OK` |
| `POLICE_COLOR_A:r,g,b,w` · `POLICE_COLOR_B:r,g,b,w` | `OK` |
| `PRESET_SAVE:0-24` · `PRESET_DELETE:0-24` | `OK` |
| `PRESET_LOAD:0-24` | `STATUS:…` or `ERROR:PRESET_EMPTY:<id>` |
| `PRESET_LIST` | `PRESETS:0,3,` (trailing comma; `PRESETS:` when empty) |
| `STATUS` | `STATUS:` + 23 fields (below) |
| `MODE_SETTINGS` | `MODE_SETTINGS:s1,f1;…;s13,f13` |
| `MODE_CAPABILITIES:m` | `CAPABILITIES:NONE` / `FREQUENCY` / `SPEED,FREQUENCY[,COLOR_MODE]` |
| `SLEEP` · `WAKE` · `SOUND_ON` · `SOUND_OFF` · `PING` | `OK` |
| `TIMER:0-86400` (seconds, 0 = cancel) | `OK` |
| `FACTORY_RESET` | `OK` (no reboot; the link stays up) |
| `INFO` · `VERSION` · `CAPS` | `INFO:EB-C3-RGBW-V1` · `VERSION:3.4.0` · `CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL` |
| `DIAG` | `DIAG:key=value,…` (see §6) |

`STATUS` fields: `r,g,b,w, brightness, mode, speed, freq` (of the active mode),
`fireworkCM, clubCM, policeCM, sleeping, timerActive, timerRemainingSec, sound,
policeA r,g,b,w, policeB r,g,b,w`.

Errors use the previous firmware's codes: `FORMAT`, `MODE_INVALID`,
`SPEED_OUT_OF_BOUNDS`, `FREQUENCY_INVALID`, `BRIGHTNESS_INVALID`, `PRESET_ID`,
`*_COLOR_MODE_INVALID`, `MODE_SPEED_INVALID`, `MODE_FREQUENCY_INVALID`,
`UNKNOWN_CMD`, and the new `STORAGE` for a flash write failure.

### Behavior notes (differences from the original firmware)
- **SLEEP turns the light off in every mode.** It also cancels the timer.
  Colour and brightness received while asleep update the stored values but do
  **not** wake the light (a late drag packet after pressing Power used to turn
  it back on). `WAKE`, `MODE` and `PRESET_LOAD` wake it.
- **When the sleep timer fires**, the light fades out over 2 s and the device
  pushes an unsolicited `STATUS`.
- **Loading a preset keeps the mute setting.** Mute is a device setting, not
  part of a scene.
- **Sleep state is not persisted.** Power-up always means light on.
- **Persistence:** the live scene is saved 3 s after the last change (at most
  15 s after the first). Sound setting and presets are saved immediately.

---

## 5. Tests

**Host tests** (portable core, ASan + UBSan, `-Werror`), 79 tests:
```bash
make -C firmware/ElectroBright/test          # all
make -C firmware/ElectroBright/test run T=club # filter by name
```
They cover:
- every command and error code
- fragmentation and flooding
- exact reply strings
- egress packing and retries
- debounce, max-latency and failure retry of the persistence
- sleep / timer / preset / mute semantics
- a simulation of every mode at the real 200 Hz frame rate: rates within ±5 %,
  monotonic slider response, Club dark time ≤ 2 % with blackouts ≤ 120 ms,
  darkness in every mode when asleep, instant parameter changes, bounded /
  NaN-free output

**On-device suite** (`pip install bleak`):
```bash
python3 firmware/ElectroBright/tools/fw_conformance.py              # contract + 30 s stress
python3 firmware/ElectroBright/tools/fw_conformance.py --stress 600 --cycles 100
python3 firmware/ElectroBright/tools/fw_conformance.py --persist    # power-cycle check
```

---

## 6. Diagnostics (`DIAG`)

| Key | Meaning |
|---|---|
| `rx` `ovf` `rej` `sdrop` | lines received · over-long lines dropped · garbage lines dropped · writes dropped (stream full) |
| `unk` `err` `coal` | unknown commands · rejected commands · lines superseded by coalescing |
| `bin` `binbad` `gaps` | binary frames ok · bad checksum · sequence gaps (lost packets) |
| `nretry` `edrop` | notify retries (stack busy) · reply lines dropped (buffer full) |
| `nvsw` `nvsf` | flash writes · flash write failures |
| `frames` `overrun` `rmaxus` | frames rendered · missed frame ticks · slowest frame (µs) |
| `heapmin` `stkc` `stkr` | minimum free heap · control / render stack headroom (bytes) |
| `rst` `up` | ESP reset reason · uptime (s) |

---

## 7. Tuning

Everything is in `src/config/Config.h`:
- PWM frequency and resolution, and phase stagger
- smoothing / crossfade / fade times
- persistence debounce
- buffer sizes
- task priorities and stacks
- `kConnectChirp` (beep on connect)

Regenerate the gamma table with `tools/gen_gamma_lut.py`.
