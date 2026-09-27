# ElectroBright W fixture (single white)

A single-channel ElectroBright light for single-colour white strips. It has the same features as the other fixtures:
- 15 presets (slots 0..14), the sleep timer and sound;
- DIAG and factory reset;
- **12 of the 13 modes**: every mode except Rainbow.

This sketch is the shared core ([`firmware/core`](../../core/ElectroBrightCore)) plus [`Fixture.h`](Fixture.h).

| | |
|---|---|
| Model id / BLE name | `EB-C3-W-V1` / `ElectroBright_C3_W_V1` |
| CAPS | `CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,LAYOUT=W,MODES=1DFF` |
| Channels | W |
| Colour on the wire | `COLOR:w` and `POLICE_COLOR_A/B:w`; 5-byte binary frame `[AA, seq, W, Br, cs]`, salt 0x54; STATUS has 14 fields |
| Flash namespace | `eb3w` (separate from the other fixtures) |

## Wiring

This uses the W position of the RGBW board (the cool-white position on the RGBCCT and CCT boards).

| Function | ESP32-C3 pin | Notes |
|---|---|---|
| White | GPIO 5 | 220 Ω to the MOSFET gate, 10 kΩ gate pull-down |
| Buzzer | GPIO 6 | passive piezo, optional 100 Ω series resistor |
| *(other LED positions)* | GPIO 1, 3, 4, 10 | not fitted; the firmware holds them low |

See [`docs/wiring_guide.md`](../../../docs/wiring_guide.md) §10.

## Modes

- **Rainbow (mode 10) is not available.** It only changes colour at constant intensity. Measured on a single white LED, it is a completely flat level. The light rejects it:
  - `MODE:10` gives `ERROR:MODE_INVALID`.
  - CAPS lists the available modes as `MODES=1DFF`, so the app can hide Rainbow.
- **Every other mode varies its intensity and works as on the other lights.** Measured variation ranges from Candle's gentle flicker (≈9 %) up to Thunderstorm's strikes.
- **Modes that make their own colours** (TV, auto Police, the auto Club and Fireworks palettes, the Fireworks embers) show them as brightness: the level of the colour's strongest channel. Red and blue Police flashes are both full-brightness flashes, TV becomes a flickering white, and Club keeps its patterns.
- **Modes that animate your chosen white** (Solid, Blink, Breath, Thunderstorm, Faulty Bulb, Welding, Fire, Candle) drive the LED exactly like the RGBW light drives its W LED. Tests prove this.
- **Defaults:** power-up and factory reset show full white. The Police manual colours are both full brightness.
- **`RGBW:` is not a command here** (`ERROR:UNKNOWN_CMD`). Frames from other fixtures' apps are rejected (`binbad` in DIAG).

## Build

Run `firmware/tools/install_ide_core.sh` once. Then open `ElectroBright_W.ino` in the Arduino IDE (board **ESP32C3 Dev Module**) and upload. See [`firmware/README.md`](../../README.md).

**Status:** host-tested and simulator-tested, including the conformance suite against fwsim. It still needs a run on real hardware with `firmware/tools/fw_conformance.py --name _W_`. The app currently accepts RGBW lights only; W support comes with the app's layout work.
