# Firmware: build, flash and release

How to build, flash and version the ESP32-C3 firmware. What the firmware *does* (modes, architecture, storage, diagnostics) is in [firmware/README.md](../firmware/README.md); the wire contract is in [protocol.md](protocol.md); the circuit is in [wiring_guide.md](wiring_guide.md).

Current version: **3.8.2** (`kFirmwareVersion` in `firmware/core/ElectroBrightCore/src/config/Config.h`).

## One image, five default types

Since 3.7.0 every sketch builds the **same universal firmware**. A sketch only calls `App::start(FixtureType::X)`, which sets the type a light with *no stored type* takes. A light that already has a type keeps it, whichever sketch is flashed; the app changes it with `SET_TYPE`. The type is stored in NVS namespace `ebsys`, key `fx`, and survives `FACTORY_RESET`.

| Sketch | Default type |
|---|---|
| `firmware/fixtures/ElectroBright_RGBW` | RGBW |
| `firmware/fixtures/ElectroBright_RGB` | RGB |
| `firmware/fixtures/ElectroBright_RGBCCT` | RGBCCT |
| `firmware/fixtures/ElectroBright_CCT` | CCT |
| `firmware/fixtures/ElectroBright_W` | W |
| `firmware/update/ElectroBright_Update` | none: a typed light keeps its type, an untyped one starts in setup-needed mode |

Each type's identity, pins and defaults are in the profile table, `firmware/core/ElectroBrightCore/src/fixture/Profiles.h`.

## Toolchain

| Item | Version |
|---|---|
| Arduino IDE | 2.x (its bundled `arduino-cli` is used by the scripts) |
| Board package | esp32 by Espressif ≥ 3.0; verified with **3.3.12** |
| Libraries | NimBLE-Arduino 2.x (verified 2.5.1); ElectroBrightCore (this repo) |
| Board | ≥ 4 MB flash ESP32-C3 (see [wiring_guide.md §3.5](wiring_guide.md#35-board-and-flash-requirement)) |

**Link the core into the IDE, once:** `firmware/tools/install_ide_core.sh` symlinks `firmware/core/ElectroBrightCore` into `~/Documents/Arduino/libraries`, so the IDE always builds the working tree. `--copy` installs a plain copy instead (re-run after every core change); `--status` shows what is installed. Restart the IDE afterwards. A sketch built against a stale copy fails with "ElectroBrightCore does not match this sketch" (`kCoreApi` check).

## Flashing with the Arduino IDE

1. **File → Open…** the sketch, e.g. `firmware/fixtures/ElectroBright_RGB/ElectroBright_RGB.ino`.
2. **Tools** settings:

| Tools menu | Setting |
|---|---|
| Board | **ESP32C3 Dev Module** |
| USB CDC On Boot | **Enabled** (serial logs over USB; the scripts use `CDCOnBoot=cdc`) |
| Partition Scheme | **Default 4MB with spiffs (1.2MB APP/1.5MB SPIFFS)**: two 1,310,720-byte app slots for wireless updates |
| Flash Size | 4MB (32Mb) |
| Port | your board |

   Other menus stay at their defaults. `sketch.yaml` in each sketch sets only `default_fqbn: esp32:esp32:esp32c3:CDCOnBoot=cdc`, so the default partition scheme applies.
3. **Upload.** The USB console prints `ElectroBright <model> <version> ready` at boot.

## Command line

```bash
firmware/tools/build.sh                 # compile every fixture sketch (--warnings all)
firmware/tools/build.sh RGB RGBW        # selected sketches (folder suffix)
OUT=/tmp/eb firmware/tools/build.sh     # keep the build outputs
firmware/tools/flash.sh RGBW            # build + upload to the one USB board, print its VERSION
firmware/tools/flash.sh CCT /dev/cu.usbmodem1101
```

`flash.sh <RGBW|RGB|RGBCCT|CCT|W> [port]` finds the port when exactly one USB board is connected, reads the flash size with esptool and stops below 4 MB, builds, uploads, then sends `VERSION` over USB and prints the reply (e.g. `VERSION:3.8.2 EB-C3-RGBW-V1`). Both scripts use the IDE's `arduino-cli` (override with `ARDUINO_CLI`) and its config (`ARDUINO_CONFIG`).

## Update image and rollback test images

```bash
firmware/tools/build_update_image.sh                       # firmware/update/dist/ElectroBright_Update-<version>.bin + .json
firmware/tools/build_update_image.sh --rollback-test fail  # test image: fails its self-check
firmware/tools/build_update_image.sh --rollback-test freeze # test image: control task freezes, watchdog resets it
```

- The update image is `firmware/update/ElectroBright_Update`. The script checks the image carries the identity block and writes a JSON sidecar (`version`, `size`, `sha256`). `OUT_DIR=…` writes elsewhere.
- Rollback test images carry version **3.8.9999** (newer than any release, so a light accepts it) and identity byte 52 = 1 (`fail`) or 2 (`freeze`). They never confirm themselves, so the light must return to its previous firmware and report DIAG `rb=1`.
- `app/tool/bundle_firmware.sh` runs these and puts the update image in `app/assets/firmware/` (with `manifest.json`) and the test images in debug-only generated Dart data. See [release.md](release.md) and the [update pipeline](architecture.md).

How the light receives, verifies and rolls back an image: [firmware/README.md](../firmware/README.md#wireless-updates-380) and [protocol.md §10](protocol.md#10-wireless-firmware-updates-380).

## Versioning

- One version for the whole family: `kFirmwareVersion` in `config/Config.h`, reported by `VERSION` (INFO carries the model id, not the version).
- In the history so far, patch releases (3.6.1 → 3.6.2, 3.8.0 → 3.8.1) fixed behaviour without new protocol, and minor releases (3.7.0, 3.8.0) added commands or services; 3.8.2, a safety fix, is a patch release with small additive protocol (CAPS `OTA=`, DIAG `pv=`/`endms=`, more `BUSY` cases). This is a convention, not enforced. The app's `EbDeviceModel.firmwareVersion` must equal this constant (`app/test/cross_repo/firmware_config_sync_test.dart`), and so must the bundled manifest (`app/test/cross_repo/firmware_bundle_test.dart`).
- Lights never accept a downgrade or the same version over the air (a reinstall needs the explicit reinstall flag).
- A version bump also needs: the golden header in `firmware/test/golden/Scenarios.cpp`, `make -C firmware/test golden-record` (VERSION appears in the transcripts), and `app/tool/bundle_firmware.sh`. Full steps: [release.md](release.md).

## Where the changelog lives

- **User-visible firmware changes:** [protocol.md §8](protocol.md#8-firmware-changes) and the root [CHANGELOG.md](../CHANGELOG.md).
- **Intended behaviour changes against the 3.4.0 RGBW baseline:** the header of `firmware/test/golden/Scenarios.cpp` (the golden file `firmware/test/golden/rgbw.golden` fails on anything not listed there).

## Tests

`make -C firmware/test` (238 host tests), `make -C firmware/test conformance`, and the on-device `firmware/tools/fw_conformance.py`. See [testing.md](testing.md).
