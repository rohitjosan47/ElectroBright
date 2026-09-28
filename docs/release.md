# Release procedure

How to cut an app release. The firmware ships **inside** the app, so an app release is also how new firmware reaches lights (there is no update server). Building and flashing firmware by hand is in [firmware.md](firmware.md); the test suites are in [testing.md](testing.md).

Current versions: app `2.0.0+200` (`app/pubspec.yaml`), firmware `3.8.1` (`kFirmwareVersion` in `firmware/core/ElectroBrightCore/src/config/Config.h`).

## 1. Bump the versions

| What | Where | Rule |
|---|---|---|
| Firmware (only if it changed) | `kFirmwareVersion` in `Config.h` | Always increase: lights refuse an older image (`Downgrade`) and the same version without the reinstall flag (`SameVersion`). Record user-visible changes in the golden changelog comment at the top of `firmware/test/golden/Scenarios.cpp` and re-record the golden (`make -C firmware/test golden-record`) only for intended changes. |
| App | `version:` in `app/pubspec.yaml` (`name+build`) | The build number (`+200`) becomes the iOS build number and the Android `versionCode`; it must increase with every store upload. |
| Changelog | [CHANGELOG.md](../CHANGELOG.md) | Plain-words entry for both. |

## 2. Bundle the firmware

```bash
app/tool/bundle_firmware.sh
```

It runs `firmware/tools/build_update_image.sh` three times (the release image and the two `--rollback-test fail|freeze` images) and writes:

- `app/assets/firmware/ElectroBright_Update-<version>.bin` and `manifest.json` (product, kind, version, size, SHA-256, file);
- `app/lib/features/developer/rollback_test_images.g.dart` (debug builds only reach it).

`test/cross_repo/firmware_bundle_test.dart` fails if the manifest doesn't match the file or `kFirmwareVersion`, so a forgotten re-bundle is caught by step 3.

## 3. Verify

```bash
app/tool/check.sh --builds
```

Format, analyze, firmware host tests, all `flutter test` suites, then an iOS simulator debug build, a signed Android release APK, and `tool/check_release_excludes_tests.sh`, which confirms the release binary contains neither the rollback test images nor the option. Then run the hardware checklists in [testing.md](testing.md) on real lights, including an over-the-air update from the previous release.

## 4. Release builds

**Android.** Release signing reads `app/android/key.properties` (git-ignored: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`). Without it, `build.gradle.kts` silently falls back to the **debug key**; such a build can't upgrade an installed app and must not be uploaded. The application id is `com.electrobright.electrobright_app` (kept from the previous app so v2 installs as an upgrade).

```bash
cd app
flutter build appbundle --release      # Play Store upload (.aab)
```

**iOS.** Bundle id `com.electrobright.electrobrightApp`, signing team set in the Xcode project.

```bash
cd app
flutter build ipa --release            # then upload with Xcode Organizer or Transporter
```

## 5. Tag

```bash
git tag -a app-2.0.0 -m "App 2.0.0 (firmware 3.8.1)"
```

The repository has no remote yet and existing tags are `fw-3.4.0-golden`, `fw-3.6.0` and `old-app-final`; the `app-<version>` / `fw-<version>` naming is a suggestion, not an established convention.

## 6. Store submission checklist

- [ ] **Developer accounts:** Apple Developer Program and Google Play Console, both active.
- [ ] **Bluetooth permission texts:**
  - iOS: `NSBluetoothAlwaysUsageDescription` = "ElectroBright uses Bluetooth to find and control your lights." (`app/ios/Runner/Info.plist`).
  - Android: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`; location only up to API 30 (`app/android/app/src/main/AndroidManifest.xml`). Play's permissions declaration: Bluetooth is used only to find and control the user's lights; no location is derived.
- [ ] **Privacy answers:** the app has no server, account, analytics or network code; it stores light names, presets and settings only on the phone. App Store privacy label "Data Not Collected"; Play Data safety "No data collected or shared". Re-check if any SDK is added.
- [ ] **Privacy manifest (iOS):** there is no `PrivacyInfo.xcprivacy` in `app/ios/Runner` today. Check whether the plugins' own manifests cover the required-reason APIs before submitting.
- [ ] **Export compliance:** `ITSAppUsesNonExemptEncryption` is **not set** in `Info.plist`, so App Store Connect asks on every upload. The app uses no encryption of its own (Bluetooth link encryption is the OS's); answer accordingly, or add the key set to `false`.
- [ ] **Icons:** `app/ios/Runner/Assets.xcassets/AppIcon.appiconset` (1024 px included) and the Android launcher icons.
- [ ] **Screenshots:** phone sizes each store requires; demo lights ("Try demo lights") show every light type without hardware.
- [ ] **Review notes:** reviewers have no ElectroBright hardware; tell them to use **Try demo lights** on the welcome screen.

## 7. How updates reach lights

```mermaid
flowchart LR
  A[Store release with<br>bundled firmware] --> B[User updates the app]
  B --> C[App connects a light<br>with the update service]
  C --> D{Light older than<br>bundled version?}
  D -- yes --> E[Update badge; user taps<br>Update firmware]
  D -- no --> F[Nothing offered]
  E --> G[Transfer, verify, restart,<br>self-check]
```

Nothing is pushed: a light updates only when a phone with the newer app connects and the user starts the update. Lights on firmware before 3.8.0 have no update service and need one USB install ([firmware.md](firmware.md)). The mechanism itself (slots, verification, rollback) is described in [architecture.md](architecture.md) and [protocol.md](protocol.md) §10.
