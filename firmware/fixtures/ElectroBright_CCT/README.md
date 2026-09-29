# ElectroBright CCT fixture

A tunable-white ElectroBright light with two channels: cool white (CW) and warm white (WW). It suits a CCT (3-pin) LED strip. It has every mode and feature of the other fixtures:
- all 13 modes, with the same sliders;
- 15 presets (slots 0..14), the sleep timer and sound;
- DIAG and factory reset.

This sketch installs the universal ElectroBright firmware (the shared core, [`firmware/core`](../../core/ElectroBrightCore)) and only sets the type a new light gets: **CCT**. A light that already has a type keeps it; the app changes it with `SET_TYPE`. This type's data is in the core's profile table ([`fixture/Profiles.h`](../../core/ElectroBrightCore/src/fixture/Profiles.h)).

| | |
|---|---|
| Model id / BLE name | `EB-C3-CCT-V1` / `ElectroBright_C3_CCT_V1` |
| CAPS | `CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=CCT` |
| Channels (wire order) | CW, WW |
| Colour on the wire | `COLOR:cw,ww` and `POLICE_COLOR_A/B:cw,ww`; 6-byte binary frame `[AA, seq, CW, WW, Br, cs]`, salt 0x57; STATUS has 17 fields |
| Flash namespace | `eb3` (every type; the type itself is in `ebsys`) |

## Wiring

This uses the white positions of the RGBCCT board.

| Function | ESP32-C3 pin | Notes |
|---|---|---|
| Cool white | GPIO 5 | 220 Ω to the MOSFET gate, 10 kΩ gate pull-down |
| Warm white | GPIO 10 | same. If your C3 board doesn't break it out, change `board::kPinWarm` in `fixture/Profiles.h` (every type shares the board pins) |
| Buzzer | GPIO 6 | passive piezo, optional 100 Ω series resistor |
| *(unused colour positions)* | GPIO 1, 3, 4 | not fitted; the firmware holds them low |

- **Parts:** two logic-level N-MOSFETs, two gate resistors and two pull-downs.
- **Strip:** a common-anode 12/24 V CCT strip, with `CW-` and `WW-` to the MOSFET drains.

See [`docs/wiring_guide.md`](../../../docs/wiring_guide.md) §9.

## Behaviour

- **Whites are raw LED levels.** `COLOR:255,0` is pure cool white and `COLOR:0,255` is pure warm white; anything in between mixes them. The app offers a colour temperature control that computes the two values.
- **Power-up and factory reset** show both whites at full.
- **Police defaults** (manual colours): A is warm, B is cool.
- **Modes that make their own colours** show them as white temperature: Rainbow, TV, auto Police, the auto Fireworks and Club palettes, and the Fireworks embers.
  - Warm hues (red, orange, yellow) play on the warm LED, cool hues (blue, cyan) on the cool LED, and neutral colours on both.
  - Brightness follows the colour's strongest channel.
  - So Rainbow sweeps warm to cool, auto Police alternates warm and cool, and TV flickers in temperature.
- **White flashes from effects** (the Club strobe and the Fireworks burst) use both LEDs.
- **Modes that animate your chosen white** (Solid, Blink, Breath, Thunderstorm, Faulty Bulb, Welding, Fire, Candle) drive the two LEDs exactly like the RGBCCT light drives its whites. Tests prove this.
- **`RGBW:` is not a command here** (`ERROR:UNKNOWN_CMD`). Frames from other fixtures' apps are rejected (`binbad` in DIAG), including RGBW's legacy 6-byte frame, which has the same length.

## Build

Run `firmware/tools/install_ide_core.sh` once. Then open `ElectroBright_CCT.ino` in the Arduino IDE (board **ESP32C3 Dev Module**) and upload. See [`firmware/README.md`](../../README.md).

**Status:** host-tested and simulator-tested, including the conformance suite against fwsim. It still needs a run on real hardware with `firmware/tools/fw_conformance.py --name _CCT_`. The app (`app/`) supports this type.
