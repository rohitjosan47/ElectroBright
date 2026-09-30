# ElectroBright

ElectroBright is a Bluetooth lighting system with three parts:
- **Hardware:** an ESP32-C3 on a small MOSFET board drives a 12 V / 24 V LED strip ([wiring guide](docs/wiring_guide.md)).
- **Firmware:** one universal image (3.8.2) for all five fixture types (RGBW, RGB, RGBCCT, CCT and W). The light stores its type, and lights update wirelessly from the app ([firmware](firmware/README.md)).
- **App:** a Flutter app for iOS and Android that talks to the lights directly over Bluetooth, with no server or cloud ([app guide](docs/app.md)).

<p>
  <img src="app/test/goldens/home_badge_dark.png" alt="Home screen" width="260">
  <img src="app/test/goldens/control_rgbcct_dark_1x.png" alt="Control screen of an RGBCCT light" width="260">
</p>

*Screenshots are the app's golden test images (`app/test/goldens/`), rendered from demo lights.*

## Get the app

**Current build:** `v1.0-rc3`, app 2.0.0+200 with firmware 3.8.2 bundled. It is a test build published as a [GitHub pre-release](https://github.com/rohitjosan47/ElectroBright/releases/tag/v1.0-rc3): the app is not on the App Store or Google Play yet, and [docs/security.md](docs/security.md) lists what a wide public release still needs. Every build: [Releases](https://github.com/rohitjosan47/ElectroBright/releases).

### Android (APK)

| Download | Size | Use it for |
|---|---|---|
| [ElectroBright-2.0.0+200-rc3-release.apk](https://github.com/rohitjosan47/ElectroBright/releases/download/v1.0-rc3/ElectroBright-2.0.0%2B200-rc3-release.apk) | 60 MB | Everyday use and testing |
| [ElectroBright-2.0.0+200-rc3-debug.apk](https://github.com/rohitjosan47/ElectroBright/releases/download/v1.0-rc3/ElectroBright-2.0.0%2B200-rc3-debug.apk) | 168 MB | Troubleshooting: adds Developer tools (fixture type, output test, Diagnostics, reinstall firmware) and BLE Lab (protocol trace) |

Needs Android 7.0 or newer with Bluetooth Low Energy.

1. Open the link on the phone and download the file.
2. Open the downloaded file. If Android asks, allow installs from your browser, then tap **Install**.
3. Open ElectroBright and allow Bluetooth when asked (Android 12 and newer: "Nearby devices"; Android 11 and older: location).

From a computer with the phone connected over USB: `adb install -r ElectroBright-2.0.0+200-rc3-release.apk`.

Both files are signed with the same key, so either one replaces the other, and both replace the previous ElectroBright app and keep its saved lights. The SHA-256 of each file is in the release notes.

### iPhone (build from source)

There is no App Store or TestFlight build yet, so the app is installed from this repository with Xcode's automatic signing. Once installed it works without the Mac.

You need a Mac with Xcode 16 or newer signed in to an Apple ID (Xcode → Settings → Accounts; a free Apple ID works), [Flutter](https://docs.flutter.dev/get-started/install) stable 3.47 or newer, an iPhone on iOS 15 or newer, and a USB cable.

1. On the iPhone (iOS 16 and newer): Settings → Privacy & Security → Developer Mode → on, and restart when asked.
2. Connect the iPhone by USB, unlock it, and tap **Trust** on the "Trust This Computer" prompt.
3. On the Mac:
   ```bash
   git clone https://github.com/rohitjosan47/ElectroBright.git
   cd ElectroBright/app
   flutter pub get
   flutter devices                       # note your iPhone's id
   flutter run --release -d <iphone-id>  # builds, signs, installs and starts the app
   ```
4. If the app refuses to open ("Untrusted Developer"): Settings → General → VPN & Device Management → the developer app → **Trust**, then open it again.

Notes:
- If the build stops with a signing error, your Apple ID is not on the project's team. Open `app/ios/Runner.xcworkspace` in Xcode once, select the **Runner** target → **Signing & Capabilities**, choose your own team, and let Xcode change the bundle identifier if it asks (a free Apple ID needs one nobody else uses). Then run the command again.
- With a free Apple ID the app stops opening after 7 days; run the same `flutter run` command again to renew it (your lights and settings are kept). A paid Apple Developer account gives a year.
- `flutter install` also works but removes the app first, which deletes its saved lights; prefer `flutter run`.
- Demo mode (**Try demo lights**) needs no hardware and also runs on the iOS Simulator with a plain `flutter run`.

### Your lights

A light needs ElectroBright firmware 3.x, flashed once over USB (`firmware/tools/flash.sh <TYPE>`, see [docs/firmware.md](docs/firmware.md)). After that the app adds it over Bluetooth and keeps its firmware up to date wirelessly. Wiring: [docs/wiring_guide.md](docs/wiring_guide.md). Using the app: [docs/user_guide.md](docs/user_guide.md).

## Repository layout

```
ElectroBright/
├── app/        Flutter app (iOS, Android): lib/, test/, integration_test/, tool/ (check, bundle firmware)
├── firmware/   ESP32-C3 firmware
│   ├── core/ElectroBrightCore/   shared core library (all fixture types)
│   ├── fixtures/                 one sketch per default type
│   ├── update/                   the type-neutral wireless-update image
│   ├── test/                     host tests, simulator (fwsim), golden baseline
│   └── tools/                    build, flash, update-image, IDE setup, conformance
├── docs/       all documentation (index: docs/README.md)
└── CHANGELOG.md
```

## Quick start

**Try the app without hardware (demo mode):**
```bash
cd app
flutter run          # on a simulator or phone, choose "Try demo lights"
```

**Build and flash a light** (macOS/Linux, with the Arduino IDE installed; see [docs/firmware.md](docs/firmware.md) for the IDE route and exact settings):
```bash
firmware/tools/install_ide_core.sh   # once: makes the shared core visible to the IDE
firmware/tools/flash.sh RGB          # build the RGB sketch, flash the connected board, print its version
```
After that, the app adds the light and keeps its firmware up to date wirelessly.

**Run the tests:** `app/tool/check.sh` (details in [docs/testing.md](docs/testing.md)).

## Documentation

- [docs/README.md](docs/README.md): index of every document, reading order and glossary
- [docs/user_guide.md](docs/user_guide.md): for people using the lights
- [CHANGELOG.md](CHANGELOG.md): app and firmware history
- [docs/release.md](docs/release.md): how a build becomes a release
