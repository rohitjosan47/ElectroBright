# ElectroBright Firmware Family (ESP32-C3)

Firmware for ElectroBright BLE light fixtures. One **shared core** holds everything the fixtures have in common:
- all 13 modes and effects;
- the BLE protocol;
- presets, the sleep timer, sound, diagnostics and persistence.

Each **fixture** is a small Arduino sketch that adds only its identity, channel layout and wiring. Every fixture works with the ElectroBright app. The protocol contract is in [`docs/protocol.md`](../docs/protocol.md), and the hardware is described in [`docs/wiring_guide.md`](../docs/wiring_guide.md).

Family version **3.5.0**

| Fixture | Sketch | Channels | Model id | BLE name | Status |
|---|---|---|---|---|---|
| RGBW | [`fixtures/ElectroBright_RGBW`](fixtures/ElectroBright_RGBW/README.md) | R, G, B, W | `EB-C3-RGBW-V1` | `ElectroBright_C3_V1` | shipping (byte-identical to 3.4.0 apart from VERSION/CAPS) |
| RGB | [`fixtures/ElectroBright_RGB`](fixtures/ElectroBright_RGB/README.md) | R, G, B | `EB-C3-RGB-V1` | `ElectroBright_C3_RGB_V1` | new; host-tested, awaiting a hardware run |

```
firmware/
  core/ElectroBrightCore/   Arduino library: the shared core (library.properties, src/)
  fixtures/<Name>/          one sketch per fixture: <Name>.ino, Fixture.h, README.md
  test/                     host tests, fwsim, golden baseline (make)
  tools/                    IDE setup, build script, conformance suite, gamma-table generator
```

---

## 1. Build & flash (Arduino IDE)

| Item | Requirement (verified) |
|---|---|
| IDE | Arduino IDE 2.x |
| Board package | **esp32 by Espressif ≥ 3.0** (verified with 3.3.11) |
| Libraries | **NimBLE-Arduino 2.x** by h2zero (verified with 2.5.1), via Library Manager; **ElectroBrightCore** (this repo, step 1) |
| Board | **ESP32C3 Dev Module** (`esp32:esp32:esp32c3`) |
| USB CDC On Boot | Enabled (only needed for serial logs) |

1. **Once:** run `firmware/tools/install_ide_core.sh`, then restart the IDE.
   - The script links `core/ElectroBrightCore` into `~/Documents/Arduino/libraries`, so every sketch always builds against the working tree.
   - `--copy` installs a plain copy instead; re-run it after every core change.
   - `--status` shows what is installed.
2. **File → Open…** the fixture's sketch, for example `firmware/fixtures/ElectroBright_RGB/ElectroBright_RGB.ino`.
3. Select the board and port, then **Upload**.

A sketch built against a stale core copy fails at compile time with "ElectroBrightCore does not match this sketch".

**Command line.** This uses the Arduino IDE's own `arduino-cli` and settings, and always builds against the working tree:
```bash
firmware/tools/build.sh            # every fixture
firmware/tools/build.sh RGB        # one fixture (folder suffix)
```

Reference build (3.5.0), per fixture: ≈655 KB flash (49 %) and 31.0 KB static RAM (9 %), with zero compiler warnings under `--warnings all`.

**First boot starts clean.** Each fixture stores its settings and presets in its own NVS namespace: `eb3` for RGBW and `eb3rgb` for RGB.
- An RGBW light updated from 3.4.0 keeps its presets, because the namespace and the byte layout are unchanged.
- Data from the original pre-3.x firmware (namespace `eeprom`) is erased once.

---

## 2. Fixtures and channel layouts

A fixture is described by a `FixtureProfile` (`core/ElectroBrightCore/src/fixture/FixtureProfile.h`). Its fields:
- **Identity:** model id, BLE name, CAPS reply, NVS namespace.
- **Channel layout:** which LED channels exist, in wire order.
- **Wiring:** one GPIO per channel, the buzzer pin, and unused outputs that must be held low.
- **Scene defaults:** colour and police colours.
- **White mix:** the linear RGB that stands in for white-channel light on a layout without W.
- **Legacy frames:** whether the pre-3.x binary frames are accepted.

The layout sets the width of every colour on the wire. `COLOR`, `POLICE_COLOR_A/B`, the binary frame and STATUS all carry one value per channel. See [`docs/protocol.md`](../docs/protocol.md).

What differs between fixtures:

| | RGBW | RGB |
|---|---|---|
| **Outputs** | GPIO 1, 3, 4, 5 → R, G, B, W | GPIO 1, 3, 4 → R, G, B; GPIO 5 held low (W not fitted) |
| **Colour command** | `COLOR:r,g,b,w` (alias `RGBW:`) | `COLOR:r,g,b` (`RGBW:` → `ERROR:UNKNOWN_CMD`) |
| **Binary frame** | 8 bytes, salt 0x55, plus the legacy 7/6-byte frames | 7 bytes, salt 0x56 |
| **STATUS** | 23 fields | 20 fields |
| **White-channel light from effects** | drives the W LED | mixed from R+G+B (hue kept) |
| **Police colour B default** | W LED `0,0,0,255` | RGB white `255,255,255` |
| **Buzzer LEDC channel** | 4 | 3 |

### Adding a fixture
1. **Layout.** If the layout is new, add it to `fixture/ChannelLayout.h`.
2. **Folder.** Copy `fixtures/ElectroBright_RGB` to `fixtures/ElectroBright_<Name>`.
   - Rename the `.ino` to match the folder.
   - Edit `Fixture.h`: identity, pins, defaults, and a unique NVS namespace (≤ 15 chars).
3. **Register.** Add it to `test/Fixtures.h` and to `FIXTURES` in `test/Makefile`. `tools/fw_conformance.py` needs the new layout in `LAYOUTS`.
4. **Check.** Run `make -C firmware/test`, `make -C firmware/test conformance` and `firmware/tools/build.sh`.

---

## 3. Architecture

```
NimBLE host task ── write callback: validate + copy only ──► colour mailbox (latest wins)
                                                         └─► text stream buffer (1 KB)
                                                                  │ notify
CONTROL task (prio 6) ── the ONLY owner of device state (actor model)
   LineAssembler → CommandParser → ControllerCore → replies (Egress → BLE notify)
   StateStore (NVS, debounced) · sleep timer · sounds
                                                                  │ SeqLock snapshot
esp_timer 200 Hz ─► RENDER task (prio 10)
   RenderEngine: smoothing → effect (+ crossfade) → channel map → brightness → sleep fade → LEDC
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
- **Phase-shifted PWM.** The n channels switch at 1/n-period offsets, which
  lowers the peak current on the strip supply and reduces EMI.
- **One core, many fixtures.** Effects always render linear RGBW; the channel
  map at the end drives the fixture's real outputs (on a light without W,
  white-channel light becomes hue-preserving RGB white).

### Source map

All paths are under `core/ElectroBrightCore/src/` unless noted.

| Path | Portable? | Purpose |
|---|---|---|
| `config/Config.h` | ✓ | Family version, rates, timings, buffer sizes (shared by every fixture) |
| `fixture/` | ✓ | `ChannelLayout` (channels in wire order), `FixtureProfile` (what a sketch passes to `App::start`) |
| `core/` | ✓ | Types, math, RNG, noise, seqlock, stats |
| `protocol/` | ✓ | Line assembler, parser, binary frames, reply formats, egress packing |
| `state/` | ✓ | Scene/settings schema, persistence policy |
| `control/ControllerCore.*` | ✓ | Command semantics, sleep timer, presets |
| `render/` | ✓ | Colour pipeline, render engine, channel map, mode registry, 13 effects |
| `feedback/` | ✓ | Buzzer melodies and sequencer |
| `platform/` | ESP32 | LEDC PWM, buzzer, NVS, NimBLE NUS, tasks/timer wiring |
| `fixtures/<Name>/Fixture.h` | ✓ | One fixture's identity, layout, pins, defaults (outside the library) |

"Portable" code has no Arduino / ESP-IDF includes (enforced by `make portable`)
and is fully covered by the host tests.

---

## 4. Modes and sliders

Protocol command names are unchanged (`SPEED:` / `FREQUENCY:`). The **UI
names** now describe what each slider really does (`core/ElectroBrightCore/src/render/ModeRegistry.h`
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

## 5. BLE protocol

Nordic UART Service with text commands and a binary colour fast path. The complete contract is in [`docs/protocol.md`](../docs/protocol.md):
- identity and layout detection;
- binary frames;
- every command and reply;
- the `3n + 11`-field STATUS;
- error codes and shared behaviour.

How this firmware differs from the original (pre-3.x) firmware:
- **Sleep:**
  - SLEEP turns the light off in every mode, and cancels the timer.
  - Colour and brightness received while asleep update the stored values but do not wake the light. In the original firmware, a late drag packet after pressing Power turned it back on.
  - `WAKE`, `MODE` and `PRESET_LOAD` wake the light.
- **Timer:** when it fires, the light fades out over 2 s and pushes an unsolicited `STATUS`.
- **Presets:** loading a preset keeps the mute setting. Mute is a device setting, not part of a scene.
- **Power-up:** sleep state is not persisted, so power-up always means light on.
- **Persistence:** the live scene is saved 3 s after the last change, and at most 15 s after the first change. The sound setting and presets are saved immediately.

---

## 6. Tests

**Host tests** (`test/`: portable core, ASan + UBSan, `-Werror`): 114 tests.
```bash
make -C firmware/test                 # portable check, all tests, fwsim
make -C firmware/test run T=rgb       # filter by name
make -C firmware/test conformance     # tools/fw_conformance.py against fwsim, every fixture
```

What they cover:
- **Protocol and state:** every command and error code; fragmentation and flooding; exact reply strings; egress packing and retries; persistence debounce, maximum latency and failure retry; sleep, timer, preset and mute semantics.
- **Render:** every mode simulated at the real 200 Hz frame rate:
  - rates within ±5 % and monotonic slider response;
  - Club dark time ≤ 2 %, with blackouts ≤ 120 ms;
  - darkness in every mode while asleep;
  - instant parameter changes;
  - bounded, NaN-free output.
- **Golden baseline:** `golden/rgbw.golden` holds render hashes for 64 streams, plus protocol transcripts with flash contents. It was recorded from 3.4.0 before the family refactor, so any change in RGBW behaviour fails the build. Re-record it only with `make golden-record`.
- **RGB fixture** (`test_rgb.cpp`):
  - widths, identity, frames and the salt;
  - rejection of RGBW frames;
  - defaults, storage validation, and presets across a reboot;
  - hue-preserving white fold;
  - effects identical to RGBW.
- **Per-fixture invariants** (`test_layouts.cpp`): identity and wiring, `3n + 11` STATUS fields, colour arity, frame round trips, binary data never reaching the text parser, and bounded rendering. These run for every fixture in `test/Fixtures.h`.

**fwsim** (`test/fwsim`) runs the real core behind a stdin/stdout protocol for the app's firmware-in-the-loop tests. Select the fixture with `--fixture rgbw|rgb` (the default is rgbw).

**On-device suite** (`pip install bleak`). It reads the layout from INFO/CAPS:
```bash
python3 firmware/tools/fw_conformance.py                 # contract + 30 s stress
python3 firmware/tools/fw_conformance.py --name RGB      # pick a fixture by name
python3 firmware/tools/fw_conformance.py --stress 600 --cycles 100
python3 firmware/tools/fw_conformance.py --persist       # power-cycle check
```

---

## 7. Diagnostics (`DIAG`)

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

## 8. Tuning

**Shared settings** are in `core/ElectroBrightCore/src/config/Config.h`:
- PWM frequency, resolution and phase stagger;
- smoothing, crossfade and fade times;
- persistence debounce;
- buffer sizes;
- task priorities and stack sizes;
- `kConnectChirp` (beep on connect).

**Per-fixture settings** are in `fixtures/<Name>/Fixture.h`: pins, defaults and `whiteMix`.

Regenerate the gamma table with `tools/gen_gamma_lut.py`.

---

## 9. Roadmap: more fixtures

The core is sized for up to 5 channels (`kMaxChannels`, `Command::args`, frame routing up to 9 bytes). The buzzer uses the first LEDC channel after the LED outputs (the C3 has 6 channels).

- **W (single white), n = 1:** needs a `W`-only layout. Effects render RGBW, so the channel map must turn colour into white brightness (for example, luminance).
- **CCT (cool + warm white) and RGBCCT (RGB + CW + WW, n = 5):** need `CW`/`WW` channel roles. Colour temperature has to be carried from the scene to the channel map, which means widening `Scene` colours beyond `Rgbw8`. That change needs a new NVS schema. The new fixtures get their own namespaces, so existing RGBW/RGB presets are unaffected.
- **App:** the app must accept `LAYOUT=RGB` (and later layouts), size colours and STATUS by `n`, and use the salted frame. See [`docs/protocol.md`](../docs/protocol.md).
