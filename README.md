# ElectroBright

ElectroBright is an intelligent RGBW ambient lighting system powered by an ESP32-C3 microcontroller and controlled wirelessly over Bluetooth Low Energy (BLE) via a modern Flutter mobile application.

## Repository Structure

```
ElectroBright/
├── firmware/
│   └── ElectroBright_ESP32C3_BLE/   # ESP32-C3 Arduino firmware (C++)
├── electrobright_app/               # Flutter mobile application (iOS, Android, macOS)
└── docs/                            # Hardware schematics & system specifications
    ├── wiring_guide.md              # Circuit wiring, MOSFETs, buck converter, and pinout guide
    ├── electrobright_mechanism.md   # Firmware architecture, timing, & BLE protocol reference
    └── app_specifications.md        # Companion app feature, control, and UI specifications
```

## Quick Start

### 1. Firmware (ESP32-C3)
1. Open the Arduino IDE.
2. Click **File → Open...** and select `firmware/ElectroBright_ESP32C3_BLE/ElectroBright_ESP32C3_BLE.ino`.
3. Select Board: **ESP32C3 Dev Module** (from the ESP32 Arduino core).
4. Select your connected USB port and click **Upload**.

### 2. Mobile App (Flutter)
```bash
cd electrobright_app
flutter pub get
flutter run
```

### 3. Hardware Documentation
* [Hardware Wiring Guide](docs/wiring_guide.md) — Circuit schematics, resistor values, and ESP32-C3 pin connections.
* [System Mechanism & BLE Protocol](docs/electrobright_mechanism.md) — Dual status LED logic, 13 lighting modes, audio events, and BLE command format.
* [Mobile App Specifications](docs/app_specifications.md) — UI control layout and feature specifications.
