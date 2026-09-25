# ElectroBright

ElectroBright is an ambient lighting system. An ESP32-C3 drives a 12 V / 24 V LED strip, and a Flutter app controls it over Bluetooth Low Energy. There is one firmware per fixture type, all built from a shared core:

| Fixture | Channels | Firmware |
|---|---|---|
| RGBW | red, green, blue, white | `firmware/fixtures/ElectroBright_RGBW` |
| RGB | red, green, blue | `firmware/fixtures/ElectroBright_RGB` |
| RGBCCT | red, green, blue, cool white, warm white | `firmware/fixtures/ElectroBright_RGBCCT` |
| CCT | cool white, warm white | `firmware/fixtures/ElectroBright_CCT` |
| W | single white | `firmware/fixtures/ElectroBright_W` |

## Repository Structure

```
ElectroBright/
├── firmware/                      # ESP32-C3 firmware family (Arduino IDE)
│   ├── core/ElectroBrightCore/    # shared core library: effects, BLE protocol, presets, timer, sound
│   ├── fixtures/                  # one sketch per fixture type (RGBW, RGB, RGBCCT, CCT, W)
│   ├── test/                      # host unit, simulation and golden tests (make)
│   └── tools/                     # IDE setup, build script, conformance suite, gamma-table generator
├── app/                           # Flutter app (iOS, Android)
└── docs/
    ├── app.md                     # app features, controls per light type, code layout
    ├── protocol.md                # BLE protocol contract for every fixture (layouts, frames, STATUS)
    ├── wiring_guide.md            # circuit, MOSFETs, buck converter and pinout (all fixtures)
    └── backup_power.md            # supercapacitor ride-through for the controller
```

## Quick Start

### 1. Firmware (ESP32-C3)
1. In the Arduino IDE, install the **esp32** board package (≥ 3.0) and the **NimBLE-Arduino** 2.x library.
2. Once: run `firmware/tools/install_ide_core.sh`. It makes the shared core library visible to the IDE. Then restart the IDE.
3. Click **File → Open...** and select your fixture's sketch, e.g. `firmware/fixtures/ElectroBright_RGB/ElectroBright_RGB.ino`.
4. Select Board: **ESP32C3 Dev Module**, select your USB port and click **Upload**.

The [firmware README](firmware/README.md) covers:
- the architecture;
- every lighting mode;
- the BLE protocol;
- the tests and on-device diagnostics.

### 2. Mobile App (Flutter)
```bash
cd app
flutter run                              # simulator: choose "Try demo lights"
flutter run --release -d <iphone-id>     # install on an iPhone (Developer Mode on)
```
Details, including every control per light type, are in [docs/app.md](docs/app.md).

### 3. Tests
```bash
make -C firmware/test                # firmware: host unit, simulation and golden tests
make -C firmware/test conformance    # protocol conformance of every fixture against the simulator
app/tool/check.sh                    # everything: format, analyze, firmware tests, conformance, app tests
```

## Documentation
* [Firmware](firmware/README.md) — covers:
  - architecture and lighting modes, with what each slider does;
  - the BLE protocol;
  - build, test and diagnostics.
* [BLE Protocol](docs/protocol.md) — the contract every fixture implements and the app speaks.
* [Hardware Wiring Guide](docs/wiring_guide.md) — circuit schematics, parts, resistor values and ESP32-C3 pin connections.
* [App](docs/app.md) — every app feature and control, per light type; code layout; how to run and test.
* [Backup Power](docs/backup_power.md) — keeping the controller alive through short power cuts.
