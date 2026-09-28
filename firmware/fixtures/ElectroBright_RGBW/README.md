# ElectroBright RGBW fixture

The original ElectroBright light: four channels, red, green, blue and a white LED, on an ESP32-C3. This sketch installs the universal ElectroBright firmware (the shared core, [`firmware/core`](../../core/ElectroBrightCore)) and only sets the type a new light gets: **RGBW**. A light that already has a type keeps it; the app changes it with `SET_TYPE`. This type's data is in the core's profile table ([`fixture/Profiles.h`](../../core/ElectroBrightCore/src/fixture/Profiles.h)).

| | |
|---|---|
| Model id / BLE name | `EB-C3-RGBW-V1` / `ElectroBright_C3_V1` |
| CAPS | `CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=RGBW` |
| Channels (wire order) | R, G, B, W |
| Colour on the wire | `COLOR:r,g,b,w` (alias `RGBW:`); 8-byte binary frame, plus the legacy 7/6-byte frames; STATUS has 23 fields |
| Flash namespace | `eb3` (every type; the type itself is in `ebsys`) |

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
