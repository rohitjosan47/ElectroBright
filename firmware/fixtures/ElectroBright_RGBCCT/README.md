# ElectroBright RGBCCT fixture

A five-channel ElectroBright light: red, green and blue make colours, and cool white (CW) plus warm white (WW) make whites. It suits an RGB+CCT ("RGBWW", 6-pin) LED strip. It has every mode and feature of the other fixtures:
- all 13 modes, with the same sliders;
- 15 presets (slots 0..14), the sleep timer and sound;
- DIAG and factory reset.

This sketch is the shared core ([`firmware/core`](../../core/ElectroBrightCore)) plus [`Fixture.h`](Fixture.h).

| | |
|---|---|
| Model id / BLE name | `EB-C3-RGBCCT-V1` / `ElectroBright_C3_RGBCCT_V1` |
| CAPS | `CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,LAYOUT=RGBCCT` |
| Channels (wire order) | R, G, B, CW, WW |
| Colour on the wire | `COLOR:r,g,b,cw,ww` and `POLICE_COLOR_A/B:r,g,b,cw,ww`; 9-byte binary frame `[AA, seq, R, G, B, CW, WW, Br, cs]`, salt 0x50; STATUS has 26 fields |
| Flash namespace | `eb3rgbcct` (separate from the other fixtures); 47-byte scene/preset records |

## Wiring

This is the RGBW board plus one channel. The W position becomes cool white, and warm white is added on GPIO 10.

| Function | ESP32-C3 pin | Notes |
|---|---|---|
| Red | GPIO 1 | 220 Ω to the MOSFET gate, 10 kΩ gate pull-down |
| Green | GPIO 3 | same |
| Blue | GPIO 4 | same |
| Cool white | GPIO 5 | same |
| Warm white | GPIO 10 | same. GPIO 10 is not a strapping, USB or UART pin. If your C3 board doesn't break it out, change `kPinWarmWhite` in `Fixture.h` |
| Buzzer | GPIO 6 | passive piezo, optional 100 Ω series resistor |

- **Parts:** five logic-level N-MOSFETs, five gate resistors and five pull-downs.
- **Strip:** a common-anode 12/24 V RGB+CCT strip, with `R-`, `G-`, `B-`, `CW-`, `WW-` to the MOSFET drains.

See [`docs/wiring_guide.md`](../../../docs/wiring_guide.md) §8.

## Behaviour

- **Whites are raw LED levels.** `COLOR:0,0,0,255,0` is pure cool white and `COLOR:0,0,0,0,255` is pure warm white; anything in between mixes them. The app will offer a Kelvin control that computes CW/WW. Colours and whites can be combined freely.
- **Power-up and factory reset** show both white LEDs at full, RGB off (a neutral white).
- **Police defaults:** A is amber, B is both whites.
- **White from effects** (the Club white strobe and the Fireworks burst flash) lights **both** white LEDs together, a neutral flash.
- **Every other effect** treats CW and WW like any other channel of the chosen colour. For example, a warm-white Thunderstorm flashes the warm LEDs. Tests prove warm and cool white behave identically in every mode.
- **`RGBW:` is not a command here** (`ERROR:UNKNOWN_CMD`). Frames from other fixtures' apps are rejected (`binbad` in DIAG).

## Build

Run `firmware/tools/install_ide_core.sh` once. Then open `ElectroBright_RGBCCT.ino` in the Arduino IDE (board **ESP32C3 Dev Module**) and upload. See [`firmware/README.md`](../../README.md).

**Status:** host-tested and simulator-tested, including the conformance suite against fwsim. It still needs a run on real hardware with `firmware/tools/fw_conformance.py --name RGBCCT`. The app currently accepts RGBW lights only; RGBCCT support comes with the app's layout work.
