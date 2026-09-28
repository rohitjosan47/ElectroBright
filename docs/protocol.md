# ElectroBright BLE protocol (firmware 3.8)

This is the contract between the ElectroBright fixtures (`firmware/`) and the app (`app/`). Every fixture speaks the same protocol. Only the **channel layout** changes one thing: how many values a colour has on the wire.

Since 3.7.0 one universal firmware image holds every fixture type. The light stores its active type, and `SET_TYPE` changes it (§9). A sketch only chooses the type a new light gets.

| Type | Sketch (default type) | Layout | Channels (wire order) | Model id | BLE name |
|---|---|---|---|---|---|
| RGBW | `firmware/fixtures/ElectroBright_RGBW` | `RGBW` | R, G, B, W (n = 4) | `EB-C3-RGBW-V1` | `ElectroBright_C3_V1` |
| RGB | `firmware/fixtures/ElectroBright_RGB` | `RGB` | R, G, B (n = 3) | `EB-C3-RGB-V1` | `ElectroBright_C3_RGB_V1` |
| RGBCCT | `firmware/fixtures/ElectroBright_RGBCCT` | `RGBCCT` | R, G, B, CW, WW (n = 5) | `EB-C3-RGBCCT-V1` | `ElectroBright_C3_RGBCCT_V1` |
| CCT | `firmware/fixtures/ElectroBright_CCT` | `CCT` | CW, WW (n = 2) | `EB-C3-CCT-V1` | `ElectroBright_C3_CCT_V1` |
| W (single white) | `firmware/fixtures/ElectroBright_W` | `W` | W (n = 1) | `EB-C3-W-V1` | `ElectroBright_C3_W_V1` |

Source of truth for each type:
- `firmware/core/ElectroBrightCore/src/fixture/Profiles.h`: the profile table (identity, layout, pins and defaults of every type).
- `firmware/core/ElectroBrightCore/src/fixture/ChannelLayout.h`: the layouts.

---

## 1. Transport

- **Service:** Nordic UART Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`.
  - RX `…0002` (phone → light): write, or write without response.
  - TX `…0003` (light → phone): notify.
- **Advertising:** the service UUID is in the advertisement. The name is in the scan response.
- **Names:** every fixture's name starts with `ElectroBright_C3_`. A 3.7.0+ light without a type (setup-needed mode, §9) is named `ElectroBright_C3_SETUP`. Firmware before 3.x is named `ElectroBright_BLE`.
- **One phone at a time:** a light stops advertising while a phone is connected.
- **Wireless updates (3.8.0+):** a second GATT service, `E1B70001-7A3C-4F4B-9E2D-5C8A1B0E0F01`, carries firmware updates (§10). It is found by service discovery; only the NUS UUID is advertised.
- **MTU:** the light offers 517 (3.8.0+; 247 before) and uses whatever the phone settles on.
- **Text:** lines end with `\n`, `\r` or `\r\n`, at most 96 characters. Longer lines are dropped whole. Command names are case-insensitive. Whitespace around fields is ignored.
- **Replies:** each reply ends with `\n`. Replies are packed into notifications of up to MTU − 3 bytes, so one notification can carry several replies, and one reply can span several notifications.
- **No request ids:** replies come back in command order.

## 2. Identifying a light and its layout

After connecting, send `INFO`, `VERSION` and `CAPS`:

```
INFO:EB-C3-<LAYOUT>-V<rev>                         e.g. INFO:EB-C3-RGB-V1
VERSION:<major>.<minor>.<patch>                    e.g. VERSION:3.7.0
CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=<LAYOUT>
```

A light in setup-needed mode (§9) answers `INFO` with `ERROR:SETUP_NEEDED` and CAPS with `LAYOUT=NONE`. A client that sees the `ElectroBright_C3_SETUP` name, or knows the light was in that mode, asks `CAPS` first.

- **Where the layout comes from:** the `LAYOUT` key in CAPS. It always equals the middle part of the model id.
- **RGBW 3.4.0:** it predates the `LAYOUT` key. Its model id `EB-C3-RGBW-V1` implies `RGBW`.
- **CAPS is `KEY=VALUE` pairs:** parse it as a map and ignore unknown keys. Keys may be added in later versions. A list value runs over commas: a part without `=` continues the previous key's value (`TYPES=RGBW,RGB,…`). `LAYOUT` is not always the last key.
- **Fixture types:** `TYPES=<list>` (3.7.0+) lists every type `SET_TYPE` accepts, in this order: `RGBW,RGB,RGBCCT,CCT,W`. If it is absent, the type cannot be changed.
- **Probe:** `PROBE=1` (3.7.0+) means the light answers `PROBE` (§9).
- **Preset slots:** `PRESETS=<n>` is the number of preset slots (15 on 3.6.0); absent on firmware before 3.6.0, where clients assume 15.
- **Identify:** `IDENTIFY=1` (3.6.1+) means the light supports the `IDENTIFY` command (§4, §6). If it is absent, the light does not; clients must not send it.
- **PWM:** `PWM=<bits>` is informational: the effective duty resolution. 3.6.1+ sends `PWM=15`: 25 kHz PWM (inaudible) with an 11-bit counter plus 4 bits of hardware dithering. Earlier firmware sends `PWM=14` (14-bit at 4.9 kHz, which can make the fixture's buck converter whine). Clients do not need it.
- **Supported modes:** `MODES=<hex mask>` (bit m−1 = mode m) is present only when a light doesn't support all 13 modes. If it is absent, all 13 are supported.
  - The single-white light sends `MODES=1DFF`: every mode except Rainbow (10), which only changes colour at constant intensity.
  - An unsupported mode behaves like an out-of-range one: `MODE:10` → `ERROR:MODE_INVALID`, `MODE_SPEED:10,s` → `ERROR:MODE_SPEED_INVALID`, `MODE_FREQUENCY:10,f` → `ERROR:MODE_FREQUENCY_INVALID`, `MODE_CAPABILITIES:10` → `ERROR:MODE_INVALID`.
  - `MODE_SETTINGS` still lists all 13 pairs.
- **Legacy firmware** (show "Firmware update needed"):
  - an INFO reply of `ElectroBright_ESP32C3_BLE`, or no `EB-` model id;
  - the name `ElectroBright_BLE`;
  - a VERSION major below 3;
  - no `PROTOCOL=1` in CAPS.

Every colour below has exactly **n** values, one per layout channel, in the order given by the table above.

On RGBCCT and CCT the two whites are raw, gamma-encoded LED levels: CW is cool white and WW is warm white. Colour temperature (Kelvin) is the app's job. It mixes CW and WW in mireds between the two LEDs' temperatures, then encodes each level like any other channel value.

## 3. Binary colour frames (fast path, no reply)

```
[0xAA, seq, c1 … cn, Br, cs]              length n + 4
cs = seq ^ c1 ^ … ^ cn ^ Br ^ salt         salt = 0x55 when n = 4, otherwise 0x55 ^ n
```

| Layout | Frame |
|---|---|
| RGBW | `[AA, seq, R, G, B, W, Br, seq^R^G^B^W^Br^0x55]` (8 bytes) |
| RGB | `[AA, seq, R, G, B, Br, seq^R^G^B^Br^0x56]` (7 bytes) |
| RGBCCT | `[AA, seq, R, G, B, CW, WW, Br, seq^R^G^B^CW^WW^Br^0x50]` (9 bytes) |
| CCT | `[AA, seq, CW, WW, Br, seq^CW^WW^Br^0x57]` (6 bytes) |
| W | `[AA, seq, W, Br, seq^W^Br^0x54]` (5 bytes) |

- `seq` counts frames. A gap increments `gaps` in DIAG.
- **Binary vs text:** a write is binary when it starts with `0xAA` and is 5 to 9 bytes long, which covers every frame length in the family. Such a write never reaches the text parser.
  - A binary write whose length or checksum is wrong counts as `binbad` and is not applied.
- **Why the salt:** a light rejects every other fixture's frames, even ones of the same length. For example, an RGB light rejects RGBW's legacy 7-byte frame, and a CCT light rejects RGBW's legacy 6-byte frame. A mismatched app can't set a wrong colour or corrupt a text command.
- **Legacy frames:** RGBW also accepts the pre-3.x forms `[AA, R, G, B, W, Br, cs]` (7 bytes) and `[AA, R, G, B, W, cs]` (6 bytes), with salt 0x55.
- **Delivery:** a frame is latest-wins. Only the newest pending frame is applied, once per control pass (≤ 50 ms), before any text in the same pass.
- **Sleep:** frames update colour and brightness while the light sleeps, but never wake it.

## 4. Commands

Colour arguments are `v1,…,vn`, each 0–255. The wrong number of values gives `ERROR:FORMAT`.

| Command | Reply |
|---|---|
| `COLOR:v1,…,vn` · `BRIGHTNESS:0-255` · `SPEED:1-10` · `FREQUENCY:1-10` | none (high-rate; `ERROR:…` on bad input) |
| `RGBW:r,g,b,w` (only on the RGBW light; same as `COLOR`) | none, or `ERROR:UNKNOWN_CMD` on other lights |
| `MODE:1-13` · `MODE_SPEED:m,1-10` · `MODE_FREQUENCY:m,1-10` (m must be a supported mode, §2) | `OK` |
| `FIREWORK_COLOR_MODE:0\|1` · `CLUB_COLOR_MODE:0\|1` · `POLICE_COLOR_MODE:0\|1` | `OK` |
| `POLICE_COLOR_A:v1,…,vn` · `POLICE_COLOR_B:v1,…,vn` | `OK` |
| `PRESET_SAVE:0-14` · `PRESET_DELETE:0-14` | `OK`, or `ERROR:STORAGE` |
| `PRESET_LOAD:0-14` | `STATUS:…` (wakes the light), or `ERROR:PRESET_EMPTY:<id>` |
| `PRESET_LIST` | `PRESETS:0,3,` (trailing comma; `PRESETS:` when empty) |
| `STATUS` | `STATUS:…` (§5) |
| `MODE_SETTINGS` | `MODE_SETTINGS:s1,f1;…;s13,f13` |
| `MODE_CAPABILITIES:m` | `CAPABILITIES:NONE` / `FREQUENCY` / `SPEED,FREQUENCY[,COLOR_MODE]` |
| `SLEEP` · `WAKE` · `PING` | `OK` |
| `IDENTIFY` (only when CAPS has `IDENTIFY=1`) | `OK` (§6) |
| `SOUND_ON` · `SOUND_OFF` | `OK` (preceded by `ERROR:STORAGE` if it could not be saved) |
| `TIMER:0-86400` (seconds; 0 cancels) | `OK` |
| `FACTORY_RESET` | `OK` (no reboot; the link stays up) |
| `INFO` · `VERSION` · `CAPS` | §2 |
| `DIAG` | `DIAG:key=value,…` (see `firmware/README.md`); 3.8.0 adds `slot=<n>` (the OTA app slot it runs from) and `rb=<0\|1>` (the last update was rolled back) at the end |
| `SET_TYPE:<RGBW\|RGB\|RGBCCT\|CCT\|W>` (only when CAPS has `TYPES=`) | `OK`, then the light restarts (§9); `ERROR:TYPE_INVALID`; `ERROR:STORAGE` |
| `PROBE:<output 0-4>:<0\|1>` (only when CAPS has `PROBE=1`) | `OK` (§9); `ERROR:PROBE_INVALID` |

**Error codes:**
- `FORMAT`, `UNKNOWN_CMD`
- `MODE_INVALID`, `SPEED_OUT_OF_BOUNDS`, `FREQUENCY_INVALID`, `BRIGHTNESS_INVALID`
- `FIREWORK_COLOR_MODE_INVALID`, `CLUB_COLOR_MODE_INVALID`, `POLICE_COLOR_MODE_INVALID`
- `MODE_SPEED_INVALID`, `MODE_FREQUENCY_INVALID`, `PRESET_ID`
- `PRESET_EMPTY:<id>`
- `STORAGE`: flash failure, reported once per boot
- `TYPE_INVALID`, `PROBE_INVALID` (3.7.0+)
- `SETUP_NEEDED` (3.7.0+): the light has no type yet and does not accept this command (§9)
- `BUSY` (3.8.0+): a wireless update is running (§10); queries still answer

## 5. STATUS

STATUS has `3n + 11` fields: 23 for RGBW, 20 for RGB, 26 for RGBCCT, 17 for CCT, 14 for W.

```
STATUS:<colour>, brightness, mode, speed, freq, fireworkCM, clubCM, policeCM,
       sleeping, timerActive, timerRemainingSec, sound, <policeA>, <policeB>
```

- `<colour>`, `<policeA>` and `<policeB>` each have n values.
- `speed` and `freq` belong to the active mode.
- **Pushed without a request** when the sleep timer fires, with `sleeping=1, timerActive=0`.
- **Also returned as the final reply to `PRESET_LOAD`,** with `sleeping=0`.

Examples (factory defaults):
```
RGBW  STATUS:255,255,255,0,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,255
RGB   STATUS:255,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,255,255,255
RGBCCT STATUS:0,0,0,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,0,255,255
CCT   STATUS:255,255,255,1,5,5,0,0,1,0,0,0,1,0,255,255,0
W     STATUS:255,255,1,5,5,0,0,1,0,0,0,1,255,255
```

## 6. Behaviour shared by every fixture

- **Sleep:**
  - `SLEEP` darkens every mode and cancels the timer.
  - `WAKE`, `MODE` and `PRESET_LOAD` wake the light.
  - Sleep is never persisted: power-up means on.
- **Timer:** when it fires, the light fades out over 2 s and pushes a STATUS.
- **Identify** (`IDENTIFY`, 3.6.1+): the light flashes twice, all LEDs full for 150 ms and then dark for 150 ms, whether it is on or asleep. The flashes skip brightness smoothing and the sleep fade. If sound is on, one short chirp plays at the start. Afterwards the light shows exactly what it showed before; an effect keeps running underneath. IDENTIFY changes no state and persists nothing, and it plays no Sleep/Wake sounds. A new `IDENTIFY` restarts the flashes. Any other state-changing command (anything except the queries `STATUS`, `MODE_SETTINGS`, `MODE_CAPABILITIES`, `PRESET_LIST`, `INFO`, `VERSION`, `CAPS`, `PING` and `DIAG`), a binary colour frame or the timer firing cancels them and then applies normally.
- **Persistence:**
  - The live scene is saved 3 s after the last change, and at most 15 s after the first change.
  - Presets and the sound setting are saved immediately.
  - Presets keep the mute setting unchanged.
- **Presets:** 15 slots, 0–14 (CAPS `PRESETS=15`). Firmware 3.6.0 clears all stored presets once on first boot after updating; the live scene and settings are kept. Firmware before 3.6.0 had 25 slots and may still list slots 15–24; clients ignore them. A light on firmware before 3.6.0 may still hold presets from the old format; they show as 'Preset N' without a preview until the light is updated to 3.6.0, which clears them.
- **White from effects:** the Club white strobe and the Fireworks flash add white-channel light, which each fixture shows on its white LEDs:
  - RGBW: the W LED.
  - RGBCCT: both CW and WW together, a neutral white.
  - CCT: both CW and WW together, a neutral white.
  - W: the white LED at full.
  - RGB (no white LED): white mixed from the RGB LEDs, with the same hue and never brighter than full scale.
- **Coloured effect light on a white-only light (CCT):** Rainbow, TV, Police (auto), and the Fireworks and Club auto palettes make their own colours. The CCT light shows them as white temperature:
  - Brightness follows the colour's strongest channel, and cool + warm together always add up to it, so brightness stays steady.
  - Warmth changes smoothly around the hue circle: red/orange are the warmest, cyan/blue the coolest, and white is neutral (both LEDs at half each). There are no jumps.
  - So Rainbow sweeps smoothly between warm and cool, and auto Police alternates warm (red) and cool (blue).
- **Coloured effect light on a single white LED (W):** it becomes brightness, the level of the colour's strongest channel. Saturated flashes (Police, Club, Fireworks) stay at full brightness. Rainbow is not available (§2).
- **Storage:** each fixture has its own flash namespace (`eb3` for RGBW, `eb3rgb` for RGB, `eb3rgbcct` for RGBCCT, `eb3cct` for CCT, `eb3w` for W). Reflashing a board with another fixture's firmware starts it with factory defaults.
- **Defaults** (power-up and factory reset):

  | Fixture | Colour | Police A / B |
  |---|---|---|
  | RGBW | RGB white | amber / the W LED |
  | RGB | RGB white | amber / RGB white |
  | RGBCCT | both white LEDs | amber / both white LEDs |
  | CCT | both white LEDs | warm / cool |
  | W | full white | full / full |

## 7. Adding a layout

1. Add it to `ChannelLayout.h` (a name plus its roles in wire order).
2. Add a `FixtureType` value and a profile to `fixture/Profiles.h` (and to `profiles::kAll`, the `TYPES=` order), and a sketch folder whose `App::start()` names the type.
3. Register the type in `firmware/test/Fixtures.h`.

The invariant tests (`test_layouts.cpp`) and `make conformance` then cover it. The channel roles are R, G, B, W, CW and WW. A layout without colour LEDs gets coloured effect light as white temperature (CW + WW) or as brightness (a single W). A layout can drop modes it cannot show (its `modes` mask, announced as CAPS `MODES`).

## 8. Firmware changes

- **3.8.0:** wireless updates over BLE with verification and rollback (§10): the update service, the image identity block, `ERROR:BUSY` for commands during a transfer, DIAG `slot=` and `rb=`, MTU 517. The type-neutral update image is `firmware/update/ElectroBright_Update` (no default type). Everything else is unchanged.
- **3.7.0:** one universal firmware for every fixture type; the light stores its type (NVS namespace `ebsys`, key `fx`, kept by `FACTORY_RESET`). New: `SET_TYPE`, `PROBE`, CAPS `TYPES=` and `PROBE=1` (before `LAYOUT=`), and setup-needed mode (§9). Every type keeps its settings and presets in namespace `eb3`; RGB, RGBCCT, CCT and W lights updated from 3.6.x start from their defaults. The rendering, frames and the other replies are unchanged.
- **3.6.2:** full brightness is a genuine 100 %. A channel at full output now holds its pin high (no PWM switching); every level below full stays PWM with an on-time shorter than a whole period. In 3.6.1 a channel at full asked the LEDC for a whole-period on-time, which it outputs as off, so 100 % came out at about 1/16 while 99 % looked right. The wire protocol, CAPS and every rendered level are unchanged.
- **3.6.1:** 25 kHz PWM (`PWM=15`), smooth colour-to-white on CCT, `IDENTIFY` (CAPS `IDENTIFY=1`).

## 9. Fixture type, probe and setup-needed mode (3.7.0+)

Every ElectroBright board has the same outputs: red GPIO 1, green 3, blue 4, white/cool 5, warm 10, buzzer 6. The light drives the outputs of its type and holds the others low.

- **`SET_TYPE:<type>`** (a `TYPES=` name, case-insensitive):
  - a different type: the light replies `OK`, stores the type, erases every preset and the scene (layouts differ; the sound setting stays), and restarts once the reply has gone out, so the link drops. It comes back as the new type: its model id, BLE name, layout, CAPS and defaults. Clients re-identify it (same device, new type) and drop what they kept about its presets;
  - the same type: `OK`, nothing changes, no restart;
  - an unknown name: `ERROR:TYPE_INVALID`. If the flash cannot be written: `ERROR:STORAGE`, and the type is unchanged;
  - lines after `SET_TYPE` in the same write are ignored.
- **`PROBE:<output>:<0|1>`** drives one physical output at a fixed moderate level (25 % duty) whatever the type, with every other LED output off: `0` red, `1` green, `2` blue, `3` white/cool (GPIO 5), `4` warm (GPIO 10). It lets the app find out what is wired.
  - One output at a time: `PROBE:n:1` replaces any other probe. `PROBE:n:0` ends probe `n` (another output: nothing changes).
  - It ends by itself after 3 s, and any other command or colour frame ends it.
  - It changes no state and stores nothing, and it works in setup-needed mode.
- **Setup-needed mode:** a light with no stored type and no default type built in (the type-neutral image used for wireless updates).
  - Every LED output stays off. It advertises as `ElectroBright_C3_SETUP`.
  - `CAPS` has `LAYOUT=NONE` (and `TYPES=`, `PROBE=1`); `VERSION` and `DIAG` answer normally.
  - `IDENTIFY` plays the chirp only, even when muted (no LED is known yet).
  - `PROBE` and `SET_TYPE` work as above. Every other command gives `ERROR:SETUP_NEEDED` (an unknown one `ERROR:UNKNOWN_CMD`), and binary colour frames are ignored.
- **Boot:** a stored type wins. Without one, a build with a default type (every sketch in `firmware/fixtures/`) stores and uses it; a build without one starts in setup-needed mode. `FACTORY_RESET` keeps the type.

## 10. Wireless firmware updates (3.8.0+)

A phone sends a new firmware image over BLE. The light writes it to its spare app slot and switches to it only when every check has passed. The running firmware and its boot selection are untouched until then, so a light can never be left without working firmware. Only ElectroBright universal images are accepted; the app sends the type-neutral update image (`firmware/tools/build_update_image.sh`: `ElectroBright_Update-<version>.bin` plus a JSON with its version, size and SHA-256). The light keeps its stored fixture type.

### Service

| | UUID | Properties |
|---|---|---|
| Update service | `E1B70001-7A3C-4F4B-9E2D-5C8A1B0E0F01` | |
| Control | `E1B70002-7A3C-4F4B-9E2D-5C8A1B0E0F01` | write with response, notify |
| Data | `E1B70003-7A3C-4F4B-9E2D-5C8A1B0E0F01` | write without response |

The phone subscribes to Control notifications before BEGIN. During a transfer the light asks for a 7.5–15 ms connection interval (iOS grants 15 ms) and the 2M PHY where supported, and restores 15–30 ms and 1M afterwards. A DATA write carries up to MTU − 3 bytes.

### Messages

Every number is little-endian.

| Request (Control) | Bytes | Reply |
|---|---|---|
| `BEGIN` | `01` size:u32 sha256:32 major:u16 minor:u16 patch:u16 flags:u8 (44 bytes; flags bit 0 = reinstall) | `BEGIN_OK` or `ERROR` |
| `END` | `02` | `END_OK` or `ERROR` |
| `ABORT` | `03` | `ABORTED` |
| `STATUS` | `04` | `STATE` |
| `DATA` (on Data) | offset:u32, payload | none, or `ACK` |

| Reply (Control notify) | Bytes | Meaning |
|---|---|---|
| `BEGIN_OK` | `81` start:u32 window:u16 | send from `start` (0, or where a transfer of the same image stopped); an ACK comes at least every `window` bytes (8192) |
| `ACK` | `82` next:u32 | the next offset the light expects |
| `END_OK` | `83` | verified and selected; the light restarts now |
| `ABORTED` | `84` | nothing of the transfer is kept |
| `STATE` | `85` state:u8 next:u32 size:u32 | 0 idle, 1 receiving, 2 restarting |
| `ERROR` | `E0` code:u8 next:u32 | see below; `next` is the expected offset while receiving |

Error codes (never silent):

| Code | Name | When |
|---|---|---|
| 1 | `BAD_SIZE` | BEGIN size 0 or larger than the spare slot (1,310,720 bytes with the default partition table); a DATA chunk past the end |
| 2 | `HASH_MISMATCH` | END: the received bytes do not have the announced SHA-256 |
| 3 | `NOT_ELECTROBRIGHT` | END: not a valid ESP32 app image, or no ElectroBright universal identity block of the announced version |
| 4 | `DOWNGRADE` | BEGIN: older than the running firmware |
| 5 | `SAME_VERSION` | BEGIN: the running version without the reinstall flag |
| 6 | `FLASH_ERROR` | the slot could not be written or selected |
| 7 | `BUSY` | another image is being received, a restart is pending, or the running firmware has not confirmed itself yet (right after an update) |
| 8 | `BAD_REQUEST` | a malformed request; END with no transfer |
| 9 | `INCOMPLETE` | END before every byte arrived (`next` says where to continue; the transfer goes on) |
| 10 | `TIMEOUT` | no DATA for 15 s: the transfer stopped (sent when it happens) |

### Transfer

1. `BEGIN`. The light checks the size against the spare slot and the version against its own: older is refused, the same version needs the reinstall flag. It replies `BEGIN_OK` with the offset to start from.
2. `DATA` chunks in order, each with its offset. The app never has more than one unacknowledged window (8192 bytes) in flight: it sends up to the next window boundary and waits for the `ACK`.
   - The light acknowledges every window boundary and the last byte with the next expected offset.
   - A duplicate or out-of-order chunk is ignored. The first one of a stretch triggers an `ACK` with the offset to continue from.
   - If no `ACK` arrives (the last chunk of a window was lost), the app asks `STATUS` and continues from `next`.
   - The light writes the image sequentially: each 4 KB flash sector is erased when the data reaches it, never the whole slot at once, so BLE stays responsive.
3. `END`. The light checks the byte count and the SHA-256, validates the image (`esp_ota_end`), reads the identity block back from the slot (magic `EBIMGID1`, product `ElectroBright`, kind `universal`, the announced version; at image offset 0x120, looked for in the first 1 KB), selects the slot for the next boot, replies `END_OK` and restarts. A failed check discards the transfer and leaves the running firmware selected.
4. `ABORT` discards the transfer at any time.

**Dropouts and resume.** A transfer survives a dropped link: the light keeps receiving state, and a `BEGIN` of the same image (same size, SHA-256 and version) replies with the offset reached. After 15 s without data the transfer stops (`ERROR:TIMEOUT`, the light returns to normal), but what arrived is kept until the light restarts: a later `BEGIN` of the same image in the same boot still resumes. `ABORT`, a failed check or another image forget it.

**During a transfer** (from `BEGIN_OK` until the transfer stops, or the restart after `END_OK`):
- every text command except the queries (`STATUS`, `MODE_SETTINGS`, `MODE_CAPABILITIES`, `PRESET_LIST`, `INFO`, `VERSION`, `CAPS`, `PING`, `DIAG`) gets `ERROR:BUSY`, and binary colour frames are ignored;
- effects, identify and probes stop. The light breathes slowly at a low level on its white LEDs (the RGB LEDs on an RGB light; nothing in setup-needed mode), driven by the LEDC's hardware fade so flash writes cannot make it stutter.

### First boot and rollback

The new firmware starts in the bootloader's pending-verify state. It confirms itself only after a self-check passes within 15 s: NVS readable, the fixture type loaded (the type the light had when it switched), the render loop running (2 s of frames) and BLE advertising or connected. If the check fails, the firmware marks itself invalid and restarts. If it crashes or hangs (task watchdog) before confirming, the bootloader does the same on the next start. Either way the previous firmware boots again, and DIAG reports `rb=1`. Until the new firmware has confirmed itself, `BEGIN` gets `BUSY`.
