# ElectroBright Firmware (ESP32-C3)

Firmware for ElectroBright BLE light fixtures. One **shared core** holds everything the fixtures have in common:
- all 13 modes and effects;
- the BLE protocol;
- 15 presets (`PRESET_SAVE` / `PRESET_LOAD` / `PRESET_DELETE` take slots 0..14), the sleep timer, sound, diagnostics and persistence.

Since 3.7.0 it is **one universal image** for every fixture type. The core holds a **profile table** (`core/ElectroBrightCore/src/fixture/Profiles.h`) with each type's identity, channel layout, wiring and defaults. The light stores its **active type** in NVS, and the app can change it (`SET_TYPE`). Every board has the same pin layout: R GPIO 1, G 3, B 4, white/cool 5, warm 10, buzzer 6.

Each **sketch** in `fixtures/` builds that same firmware. The only thing a sketch sets is the **default type for a first install**: a light that has no type yet takes the sketch's type. A light that already has a type keeps it, whichever sketch is flashed. Every type works with the ElectroBright app. The protocol contract is in [`docs/protocol.md`](../docs/protocol.md), and the hardware is described in [`docs/wiring_guide.md`](../docs/wiring_guide.md).

Firmware version **3.7.0**

| Type | Sketch (default type) | Channels | Model id | BLE name | Status |
|---|---|---|---|---|---|
| RGBW | [`fixtures/ElectroBright_RGBW`](fixtures/ElectroBright_RGBW/README.md) | R, G, B, W | `EB-C3-RGBW-V1` | `ElectroBright_C3_V1` | shipping. Same behaviour as 3.4.0 except VERSION/CAPS, IDENTIFY and the handling of malformed 5- and 9-byte writes |
| RGB | [`fixtures/ElectroBright_RGB`](fixtures/ElectroBright_RGB/README.md) | R, G, B | `EB-C3-RGB-V1` | `ElectroBright_C3_RGB_V1` | new; host-tested, awaiting a hardware run |
| RGBCCT | [`fixtures/ElectroBright_RGBCCT`](fixtures/ElectroBright_RGBCCT/README.md) | R, G, B, cool white, warm white | `EB-C3-RGBCCT-V1` | `ElectroBright_C3_RGBCCT_V1` | new; host-tested, awaiting a hardware run |
| CCT | [`fixtures/ElectroBright_CCT`](fixtures/ElectroBright_CCT/README.md) | cool white, warm white | `EB-C3-CCT-V1` | `ElectroBright_C3_CCT_V1` | new; host-tested, awaiting a hardware run |
| W | [`fixtures/ElectroBright_W`](fixtures/ElectroBright_W/README.md) | single white | `EB-C3-W-V1` | `ElectroBright_C3_W_V1` | new; host-tested, awaiting a hardware run. 12 modes (no Rainbow) |

```
firmware/
  core/ElectroBrightCore/   Arduino library: the shared core (library.properties, src/)
  fixtures/<Name>/          one sketch per type: <Name>.ino (only sets a new light's type), README.md
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
2. **File → Open…** the sketch of the type a new light should get, for example `firmware/fixtures/ElectroBright_RGB/ElectroBright_RGB.ino`. (A light that already has a type keeps it.)
3. Select the board and port, then **Upload**.

A sketch built against a stale core copy fails at compile time with "ElectroBrightCore does not match this sketch".

**Command line.** This uses the Arduino IDE's own `arduino-cli` and settings, and always builds against the working tree:
```bash
firmware/tools/build.sh            # every sketch
firmware/tools/build.sh RGB        # one sketch (folder suffix)
```

Reference build (3.7.0), identical for every sketch: 661,961 bytes flash (50 % of a 1,280 KB app slot) and 31.0 KB static RAM (9 %), with zero compiler warnings under `--warnings all`. The default partition scheme has two OTA app slots.

**Storage.** Every type keeps its settings, scene and presets in NVS namespace `eb3`. The fixture type is one byte, key `fx`, in its own namespace `ebsys`, so `FACTORY_RESET` (which erases `eb3`) keeps it.
- At boot the stored type wins. Without one, the sketch's default type is saved and used. A build without a default never invents a type: it starts in setup-needed mode (see section 2).
- Updating from 3.6.x: an RGBW light keeps its scene and presets (it always used `eb3`). The other types used their own namespaces (`eb3rgb`, `eb3rgbcct`, `eb3cct`, `eb3w`); 3.7.0 no longer reads them, so those lights start from their type's defaults.
- Data from the original pre-3.x firmware (namespace `eeprom`) is erased once.

> **MOSFET gate drive at 25 kHz (3.6.1+).** The PWM now switches about five
> times as often as before, so large MOSFETs (e.g. IRLZ44N) driven through the
> 220 Ω gate resistor spend more time in their linear region and run warmer.
> If they get warm, use a 100 Ω gate resistor or a low-gate-charge MOSFET
> (AO3400, IRLB8721).

---

## 2. Fixtures and channel layouts

A fixture type is described by a `FixtureProfile` (`core/ElectroBrightCore/src/fixture/FixtureProfile.h`), one entry per type in the profile table (`fixture/Profiles.h`). Its fields:
- **Identity:** type, model id, BLE name. The CAPS reply is built from the layout (`replies::caps`).
- **Channel layout:** which LED channels exist, in wire order.
- **Wiring:** one GPIO per channel, the buzzer pin, and unused outputs that must be held low.
- **Scene defaults:** colour and police colours.
- **White mix:** the linear RGB that stands in for white-channel light on a layout with no white LED.
- **Legacy frames:** whether the pre-3.x binary frames are accepted.

Every colour in the core has five slots: `r, g, b`, `w` (the primary white LED: W, or cool white) and `ww` (warm white). The layout says which LEDs exist and which slot drives each one. The layout sets the width of every colour on the wire. `COLOR`, `POLICE_COLOR_A/B`, the binary frame and STATUS all carry one value per channel. See [`docs/protocol.md`](../docs/protocol.md).

What differs between fixtures:

| | RGBW | RGB | RGBCCT | CCT | W |
|---|---|---|---|---|---|
| **Outputs** | GPIO 1, 3, 4, 5 → R, G, B, W; GPIO 10 held low | GPIO 1, 3, 4 → R, G, B; GPIO 5, 10 held low | GPIO 1, 3, 4, 5, 10 → R, G, B, CW, WW | GPIO 5, 10 → CW, WW; GPIO 1, 3, 4 held low | GPIO 5 → W; GPIO 1, 3, 4, 10 held low |
| **Colour command** | `COLOR:r,g,b,w` (alias `RGBW:`) | `COLOR:r,g,b` | `COLOR:r,g,b,cw,ww` | `COLOR:cw,ww` | `COLOR:w` |
| **Binary frame** | 8 bytes, salt 0x55, plus the legacy 7/6-byte frames | 7 bytes, salt 0x56 | 9 bytes, salt 0x50 | 6 bytes, salt 0x57 | 5 bytes, salt 0x54 |
| **STATUS** | 23 fields | 20 fields | 26 fields | 17 fields | 14 fields |
| **Modes** | 13 | 13 | 13 | 13 | 12: no Rainbow (CAPS `MODES=1DFF`) |
| **White-channel light from effects** | drives the W LED | mixed from R+G+B (hue kept) | both white LEDs (neutral) | both white LEDs (neutral) | the W LED |
| **Coloured light from effects** | RGB LEDs | RGB LEDs | RGB LEDs | white temperature (warm hues → WW, cool hues → CW) | brightness (strongest channel) |
| **Default colour** | RGB white | RGB white | both white LEDs | both white LEDs | full white |
| **Police colour A / B default** | amber / W LED | amber / RGB white | amber / both whites | warm / cool | full / full |
| **Flash record** | 44 bytes (3.4.0 format) | 44 bytes | 47 bytes (+ warm white of colour and police A/B) | 47 bytes | 44 bytes |
| **Buzzer LEDC channel** | 4 | 3 | 5 | 2 | 1 |

`RGBW:` exists only on the RGBW light. On the other fixtures it gives `ERROR:UNKNOWN_CMD`.

The active type drives only its own outputs; every other board output is held low as a plain GPIO from the first moment of boot.

### Changing the type, finding the wiring, setup-needed mode (3.7.0)
- **`SET_TYPE:<RGBW|RGB|RGBCCT|CCT|W>`** replies `OK`, stores the type, clears every preset and the scene (layouts differ; the sound setting stays) and restarts once the reply has gone out, so the link drops. The same type is an `OK` that changes nothing. Anything else is `ERROR:TYPE_INVALID`.
- **`PROBE:<output 0-4>:<0|1>`** drives one physical output (0 red GPIO 1, 1 green GPIO 3, 2 blue GPIO 4, 3 white/cool GPIO 5, 4 warm GPIO 10) at 25 % duty, whatever the type, and every other LED output off. One output at a time; it switches itself off after 3 s, any other command switches it off, and nothing is stored. An output outside the active layout borrows the LEDC channel after the buzzer's.
- **Setup-needed mode:** no stored type and no default. Every LED output stays low. The light advertises as `ElectroBright_C3_SETUP`, answers CAPS with `LAYOUT=NONE`, and accepts only `CAPS`, `VERSION`, `DIAG`, `PROBE`, `IDENTIFY` (buzzer chirp only) and `SET_TYPE`; anything else is `ERROR:SETUP_NEEDED`.
- CAPS of every type carries `TYPES=RGBW,RGB,RGBCCT,CCT,W` and `PROBE=1`, before `LAYOUT=`.

### Adding a fixture type
1. **Layout.** If the layout is new, add it to `fixture/ChannelLayout.h`.
2. **Profile.** Add a `FixtureType` value (`fixture/FixtureProfile.h`; never renumber, the value is stored) and a profile to `fixture/Profiles.h`, including it in `profiles::kAll` (the CAPS `TYPES=` order).
3. **Sketch.** Copy `fixtures/ElectroBright_RGB` to `fixtures/ElectroBright_<Name>`, rename the `.ino` to match the folder, and set its `App::start(FixtureType::<Name>)`.
4. **Register.** Add it to `test/Fixtures.h` and to `FIXTURES` in `test/Makefile`. `tools/fw_conformance.py` needs the new layout in `LAYOUTS`.
5. **Check.** Run `make -C firmware/test`, `make -C firmware/test conformance` and `firmware/tools/build.sh`.

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
   (all in five colour slots: r, g, b, w, ww)
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
- **Inaudible PWM.** 25 kHz, above hearing, so the fixtures' buck converters
  do not whine under the pulsed load (4.9 kHz before 3.6.1). At 80 MHz that
  leaves an 11-bit counter; the C3's LEDC hardware dithering adds 4
  fractional bits (15 bits effective). The dimmest level is one whole count
  every period, a steady pulse train that never flickers.
- **True 100 % (3.6.2+).** The LEDC cannot produce an on-time of a whole
  period (it outputs such a period as off), so full output is not PWM: the
  channel is stopped with its pin held high. Every level below full is PWM
  with an on-time of at most period - 1 counts, dither included
  (`platform/PwmPlan.h`, tested for every duty). In 3.6.1 full brightness
  came out at about 1/16 while 99 % was fine.
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
| `fixture/` | ✓ | `ChannelLayout` (channels in wire order), `FixtureProfile`, the profile table (`Profiles.h`), the stored type and PROBE routing (`FixtureSelect`) |
| `core/` | ✓ | Types, math, RNG, noise, seqlock, stats |
| `protocol/` | ✓ | Line assembler, parser, binary frames, reply formats, egress packing |
| `state/` | ✓ | Scene/settings schema, flash record codec (`SceneCodec`), persistence policy |
| `control/ControllerCore.*` | ✓ | Command semantics, sleep timer, presets |
| `render/` | ✓ | Colour pipeline, render engine, channel map, mode registry, 13 effects |
| `feedback/` | ✓ | Buzzer melodies and sequencer |
| `platform/` | ESP32 | LEDC PWM, buzzer, NVS, NimBLE NUS, tasks/timer wiring |
| `fixtures/<Name>/<Name>.ino` | ESP32 | A sketch: starts the core with a new light's default type (outside the library) |

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
- **Identify (3.6.1+, CAPS `IDENTIFY=1`):** `IDENTIFY` flashes the light twice (150 ms full, 150 ms dark), even when it is asleep, then resumes its previous output. It changes no state.
- **Timer:** when it fires, the light fades out over 2 s and pushes an unsolicited `STATUS`.
- **Presets:** 15 slots, 0..14 (CAPS announces `PRESETS=15`). Loading a preset keeps the mute setting. Mute is a device setting, not part of a scene.
- **Power-up:** sleep state is not persisted, so power-up always means light on.
- **Persistence:** the live scene is saved 3 s after the last change, and at most 15 s after the first change. The sound setting and presets are saved immediately.

---

## 6. Tests

**Host tests** (`test/`: portable core, ASan + UBSan, `-Werror`): 201 tests.
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
- **Golden baseline:** `golden/rgbw.golden` holds render hashes for 64 streams, plus protocol transcripts with flash contents. It was recorded from 3.4.0 before the family refactor, so any change in RGBW behaviour fails the build. Its header lists the intended changes since then. Re-record it only with `make golden-record`.
- **RGB fixture** (`test_rgb.cpp`):
  - widths, identity, frames and the salt;
  - rejection of RGBW frames;
  - defaults, storage validation, and presets across a reboot;
  - hue-preserving white fold;
  - effects identical to RGBW.
- **RGBCCT fixture** (`test_rgbcct.cpp`):
  - widths, identity, frames, defaults and 47-byte records;
  - presets across a reboot;
  - warm/cool white symmetry in every mode, through smoothing, crossfades, fades and brightness;
  - effect white on both whites;
  - effects identical to RGBW.
- **CCT fixture** (`test_cct.cpp`):
  - widths, frames (including RGBW's same-length legacy frame), defaults and records;
  - presets across a reboot;
  - the colour-to-white-temperature map;
  - colour modes playing in temperature;
  - warm/cool symmetry;
  - parity with the RGBCCT whites.
- **Single-white fixture** (`test_w.cpp`):
  - widths, identity with `MODES`, and the removed Rainbow (commands and stored scenes);
  - frames, defaults and presets across a reboot;
  - colour becoming brightness;
  - the measurement that shows Rainbow is flat on one LED while every other mode varies;
  - parity with the RGBW W LED.
- **Scene codec** (`test_state.cpp`): the legacy flash format, byte for byte, plus round trips for every fixture.
- **Per-fixture invariants** (`test_layouts.cpp`): identity and wiring (driven plus parked = all five board outputs), CAPS, `3n + 11` STATUS fields, colour arity, frame round trips, binary data never reaching the text parser, and bounded rendering. These run for every type in `test/Fixtures.h`.
- **Universal firmware** (`test_universal.cpp`): the boot choice of type (stored, build default, none); `SET_TYPE` (stored, presets cleared, scene reset, restart, invalid names, same type); setup-needed mode (outputs off, only the setup commands); `PROBE` (the right pin for every output and type, expiry, cancellation, nothing stored); `FACTORY_RESET` keeping the type; the parked outputs of every type.

The per-fixture tests run the universal build with each type selected: `Rig` and `SimDevice` boot through the same type selection as the device (`fxselect::select`).

**fwsim** (`test/fwsim`) runs the real core behind a stdin/stdout protocol for the app's firmware-in-the-loop tests. `--fixture rgbw|rgb|rgbcct|cct|w` sets the build's default type (the default is rgbw); `--fixture none` is a build without one (setup-needed mode). `SET_TYPE` restarts the simulated light as the new type and drops the link.

**On-device suite** (`pip install bleak`). It reads the layout from INFO/CAPS:
```bash
python3 firmware/tools/fw_conformance.py                 # contract + 30 s stress
python3 firmware/tools/fw_conformance.py --name RGBCCT   # pick a fixture by BLE-name substring
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
- PWM frequency, resolution, minimum duty and phase stagger;
- IDENTIFY flash timing;
- smoothing, crossfade and fade times;
- persistence debounce;
- buffer sizes;
- task priorities and stack sizes;
- `kConnectChirp` (beep on connect).

**Per-type settings** are in the profile table, `fixture/Profiles.h`: pins, defaults and `whiteMix`. The white light that effects add is set in two constants: Club `kWhite` and the Fireworks burst flash.

Regenerate the gamma table with `tools/gen_gamma_lut.py`.

---

## 9. Fixture roadmap

- **Done:** RGBW, RGB, RGBCCT, CCT, W. This covers every common strip type.
- **Core limits:** up to 5 LED channels (`kMaxChannels`, `Command::args`, frames 5–9 bytes). The buzzer takes the first LEDC channel after the LEDs, and the C3 has 6 channels.
- **Modes per layout:** a layout can drop modes it cannot show (its `modes` mask, announced as CAPS `MODES`).
- **App:** the app (`app/`) reads each light's layout and CAPS `MODES`, and builds its controls from them. It offers a colour temperature control on CCT and RGBCCT and an intensity-only control on W. See [`docs/app.md`](../docs/app.md).
- **A new fixture type** is added in three places:
  - the firmware: a `layouts::` entry, a profile in `fixture/Profiles.h` and a sketch;
  - `firmware/test/Fixtures.h`;
  - the app's `EbFixtureCatalog`.

  The cross-repo tests fail until all three agree.
