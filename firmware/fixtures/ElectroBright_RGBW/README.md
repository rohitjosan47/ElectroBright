# ElectroBright RGBW fixture

The original ElectroBright light: four channels, red, green, blue and a white LED, on an ESP32-C3. This sketch is the shared core ([`firmware/core`](../../core/ElectroBrightCore)) plus [`Fixture.h`](Fixture.h).

| | |
|---|---|
| Model id / BLE name | `EB-C3-RGBW-V1` / `ElectroBright_C3_V1` |
| CAPS | `CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,LAYOUT=RGBW` |
| Channels (wire order) | R, G, B, W |
| Colour on the wire | `COLOR:r,g,b,w` (alias `RGBW:`); 8-byte binary frame, plus the legacy 7/6-byte frames; STATUS has 23 fields |
| Flash namespace | `eb3`: presets from firmware 3.4.0 are kept |

## Wiring

| Function | ESP32-C3 pin | Notes |
|---|---|---|
| Red | GPIO 1 | 220 Ω to the MOSFET gate, 10 kΩ gate pull-down |
| Green | GPIO 3 | same |
| Blue | GPIO 4 | same |
| White | GPIO 5 | same |
| Buzzer | GPIO 6 | passive piezo, optional 100 Ω series resistor |

Four logic-level N-MOSFETs (IRLZ44N, IRLB8721, AO3400 …) switch a common-anode 12/24 V RGBW strip. The full circuit, BOM and checklist are in [`docs/wiring_guide.md`](../../../docs/wiring_guide.md).

## Build

Run `firmware/tools/install_ide_core.sh` once. Then open `ElectroBright_RGBW.ino` in the Arduino IDE (board **ESP32C3 Dev Module**) and upload. See [`firmware/README.md`](../../README.md).
