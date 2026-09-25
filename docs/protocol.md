# ElectroBright BLE protocol (firmware family 3.6)

This is the contract between the ElectroBright fixtures (`firmware/`) and the app (`app/`). Every fixture speaks the same protocol. Only the **channel layout** changes one thing: how many values a colour has on the wire.

| Fixture | Sketch | Layout | Channels (wire order) | Model id | BLE name |
|---|---|---|---|---|---|
| RGBW | `firmware/fixtures/ElectroBright_RGBW` | `RGBW` | R, G, B, W (n = 4) | `EB-C3-RGBW-V1` | `ElectroBright_C3_V1` |
| RGB | `firmware/fixtures/ElectroBright_RGB` | `RGB` | R, G, B (n = 3) | `EB-C3-RGB-V1` | `ElectroBright_C3_RGB_V1` |
| RGBCCT | `firmware/fixtures/ElectroBright_RGBCCT` | `RGBCCT` | R, G, B, CW, WW (n = 5) | `EB-C3-RGBCCT-V1` | `ElectroBright_C3_RGBCCT_V1` |
| CCT | `firmware/fixtures/ElectroBright_CCT` | `CCT` | CW, WW (n = 2) | `EB-C3-CCT-V1` | `ElectroBright_C3_CCT_V1` |
| W (single white) | `firmware/fixtures/ElectroBright_W` | `W` | W (n = 1) | `EB-C3-W-V1` | `ElectroBright_C3_W_V1` |

Source of truth for each fixture:
- `firmware/fixtures/<Name>/Fixture.h`: identity, layout, pins and defaults.
- `firmware/core/ElectroBrightCore/src/fixture/ChannelLayout.h`: the layouts.

---

## 1. Transport

- **Service:** Nordic UART Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`.
  - RX `…0002` (phone → light): write, or write without response.
  - TX `…0003` (light → phone): notify.
- **Advertising:** the service UUID is in the advertisement. The name is in the scan response.
- **Names:** every fixture's name starts with `ElectroBright_C3_`. Firmware before 3.x is named `ElectroBright_BLE`.
- **One phone at a time:** a light stops advertising while a phone is connected.
- **Text:** lines end with `\n`, `\r` or `\r\n`, at most 96 characters. Longer lines are dropped whole. Command names are case-insensitive. Whitespace around fields is ignored.
- **Replies:** each reply ends with `\n`. Replies are packed into notifications of up to MTU − 3 bytes, so one notification can carry several replies, and one reply can span several notifications.
- **No request ids:** replies come back in command order.

## 2. Identifying a light and its layout

After connecting, send `INFO`, `VERSION` and `CAPS`:

```
INFO:EB-C3-<LAYOUT>-V<rev>                         e.g. INFO:EB-C3-RGB-V1
VERSION:<major>.<minor>.<patch>                    e.g. VERSION:3.6.0
CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,LAYOUT=<LAYOUT>
```

- **Where the layout comes from:** the `LAYOUT` key in CAPS. It always equals the middle part of the model id.
- **RGBW 3.4.0:** it predates the `LAYOUT` key. Its model id `EB-C3-RGBW-V1` implies `RGBW`.
- **CAPS is `KEY=VALUE` pairs:** parse it as a map and ignore unknown keys. Keys may be added in later versions.
- **Preset slots:** `PRESETS=<n>` is the number of preset slots (15 on 3.6.0); absent on firmware before 3.6.0, where clients assume 15.
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
| `SOUND_ON` · `SOUND_OFF` | `OK` (preceded by `ERROR:STORAGE` if it could not be saved) |
| `TIMER:0-86400` (seconds; 0 cancels) | `OK` |
| `FACTORY_RESET` | `OK` (no reboot; the link stays up) |
| `INFO` · `VERSION` · `CAPS` | §2 |
| `DIAG` | `DIAG:key=value,…` (see `firmware/README.md`) |

**Error codes:**
- `FORMAT`, `UNKNOWN_CMD`
- `MODE_INVALID`, `SPEED_OUT_OF_BOUNDS`, `FREQUENCY_INVALID`, `BRIGHTNESS_INVALID`
- `FIREWORK_COLOR_MODE_INVALID`, `CLUB_COLOR_MODE_INVALID`, `POLICE_COLOR_MODE_INVALID`
- `MODE_SPEED_INVALID`, `MODE_FREQUENCY_INVALID`, `PRESET_ID`
- `PRESET_EMPTY:<id>`
- `STORAGE`: flash failure, reported once per boot

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
  - Brightness follows the colour's strongest channel.
  - Warm hues (red, orange, yellow) go to the warm LED, cool hues (blue, cyan) to the cool LED, and neutral ones to both.
  - So Rainbow sweeps warm to cool, and auto Police alternates warm and cool.
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
2. Add a fixture folder with a `Fixture.h` and a sketch.
3. Register the fixture in `firmware/test/Fixtures.h`.

The invariant tests (`test_layouts.cpp`) and `make conformance` then cover it. The channel roles are R, G, B, W, CW and WW. A layout without colour LEDs gets coloured effect light as white temperature (CW + WW) or as brightness (a single W). A layout can drop modes it cannot show (its `modes` mask, announced as CAPS `MODES`).
