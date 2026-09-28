# ElectroBright RGB fixture

A three-channel ElectroBright light (red, green and blue) on the RGBW board without its white channel. It has every mode and feature of the RGBW light:
- all 13 modes, with the same sliders;
- 15 presets (slots 0..14), the sleep timer and sound;
- DIAG and factory reset.

This sketch installs the universal ElectroBright firmware (the shared core, [`firmware/core`](../../core/ElectroBrightCore)) and only sets the type a new light gets: **RGB**. A light that already has a type keeps it; the app changes it with `SET_TYPE`. This type's data is in the core's profile table ([`fixture/Profiles.h`](../../core/ElectroBrightCore/src/fixture/Profiles.h)).

| | |
|---|---|
| Model id / BLE name | `EB-C3-RGB-V1` / `ElectroBright_C3_RGB_V1` |
| CAPS | `CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=RGB` |
| Channels (wire order) | R, G, B |
| Colour on the wire | `COLOR:r,g,b` and `POLICE_COLOR_A/B:r,g,b`; 7-byte binary frame `[AA, seq, R, G, B, Br, cs]`, salt 0x56; STATUS has 20 fields |
| Flash namespace | `eb3` (every type; the type itself is in `ebsys`) |

## Wiring

This is the RGBW board with the white channel left unpopulated.

| Function | ESP32-C3 pin | Notes |
|---|---|---|
| Red | GPIO 1 | 220 Ω to the MOSFET gate, 10 kΩ gate pull-down |
| Green | GPIO 3 | same |
| Blue | GPIO 4 | same |
| *(White, not fitted)* | GPIO 5 | leave the MOSFET off. The firmware still drives GPIO 5 low, so a fitted gate can never float on |
| Buzzer | GPIO 6 | passive piezo, optional 100 Ω series resistor |

- **Parts:** three logic-level N-MOSFETs, three 220 Ω gate resistors and three 10 kΩ pull-downs.
- **Strip:** a common-anode 12/24 V RGB strip, with strip `R-`, `G-`, `B-` to the MOSFET drains.
- **Existing RGBW boards:** they can run this firmware with an RGB strip. The W MOSFET stays off.

See [`docs/wiring_guide.md`](../../../docs/wiring_guide.md) §7 for the circuit.

## What differs from RGBW

- **No white LED.** Effects that use the white channel still work: the Club white strobe and the Fireworks flash mix white from R+G+B. The hue is kept and nothing goes above full scale (`whiteMix` of the RGB profile in `fixture/Profiles.h`).
- **Police colour B** defaults to RGB white `255,255,255`. On RGBW it is the white LED.
- **`RGBW:` is not a command here** (`ERROR:UNKNOWN_CMD`). Frames from an RGBW app are rejected (`binbad` in DIAG), so they never set a wrong colour.

## Build

Run `firmware/tools/install_ide_core.sh` once. Then open `ElectroBright_RGB.ino` in the Arduino IDE (board **ESP32C3 Dev Module**) and upload. See [`firmware/README.md`](../../README.md).

**Status:** host-tested and simulator-tested, including the full conformance suite against fwsim. It still needs a run on real hardware with `firmware/tools/fw_conformance.py --name RGB`. The app (`app/`) supports this type.
