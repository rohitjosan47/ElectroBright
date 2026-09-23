# ElectroBright

ElectroBright is an RGBW ambient lighting system. An ESP32-C3 drives a 12 V / 24 V RGBW LED strip, and a Flutter app controls it over Bluetooth Low Energy.

## Repository Structure

```
ElectroBright/
├── firmware/
│   └── ElectroBright/             # ESP32-C3 firmware (Arduino IDE sketch)
│       ├── ElectroBright.ino
│       ├── src/                   # portable core (protocol, state, effects) + ESP32 platform layer
│       ├── test/                  # host unit & simulation tests (make)
│       └── tools/                 # on-device conformance suite, gamma-table generator
├── electrobright_app/             # Flutter app (iOS, Android, macOS)
└── docs/
    ├── wiring_guide.md                    # circuit, MOSFETs, buck converter and pinout
    ├── ESP32C3_Backup_Power_Solution.md   # supercapacitor ride-through for the controller
    └── app_specifications.md              # app features and controls
```

## Quick Start

### 1. Firmware (ESP32-C3)
1. In the Arduino IDE, install the **esp32** board package (≥ 3.0) and the **NimBLE-Arduino** 2.x library.
2. Click **File → Open...** and select `firmware/ElectroBright/ElectroBright.ino`.
3. Select Board: **ESP32C3 Dev Module**, select your USB port and click **Upload**.

The [firmware README](firmware/ElectroBright/README.md) covers:
- the architecture;
- every lighting mode;
- the BLE protocol;
- the tests and on-device diagnostics.

### 2. Mobile App (Flutter)
```bash
cd electrobright_app
flutter pub get
flutter run
```

### 3. Tests
```bash
make -C firmware/ElectroBright/test          # firmware: host unit + effect simulation tests
cd electrobright_app && flutter test         # app
```

## Documentation
* [Firmware](firmware/ElectroBright/README.md) — covers:
  - architecture and lighting modes, with what each slider does;
  - the BLE protocol;
  - build, test and diagnostics.
* [Hardware Wiring Guide](docs/wiring_guide.md) — circuit schematics, parts, resistor values and ESP32-C3 pin connections.
* [Backup Power Solution](docs/ESP32C3_Backup_Power_Solution.md) — keeping the controller alive through short power cuts.
* [App Specifications](docs/app_specifications.md) — every app feature and control.
