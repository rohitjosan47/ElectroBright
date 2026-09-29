# Privacy

This page describes what the ElectroBright app and lights store and send, as of app 2.0.0+200 and firmware 3.8.2. It can serve as the basis for the App Store and Google Play privacy answers and for a public privacy page. The security side (who can connect to a light) is in [security.md](security.md).

## In short

- The app collects nothing. There are no accounts, no analytics, no crash reporting, no ads and no server.
- The app sends nothing over the internet. It talks only to your lights, directly over Bluetooth.
- Everything the app remembers stays on your phone.

## What the app stores, and where

All app data is in one folder in the app's private storage on the phone (`getApplicationSupportDirectory()/store`, written by `app/lib/core/store/json_store.dart`). Deleting the app deletes it.

| Data | Why |
|---|---|
| Saved lights: Bluetooth device id, name, type, favourite, last known state | To list and reconnect your lights |
| Preset names and previews (`presetMeta`) | The lights store the preset looks; the names live on the phone |
| Groups: members, levels, own-settings and excluded lists, the group's last look, group presets | To run groups the same way next time |
| Lights hidden as "Not mine" (`hiddenLights`) | To keep them out of the list |
| Settings (for example whether developer tools are on, and one-time migration flags) | App preferences |

On the first launch the app reads the previous ElectroBright app's saved lights once, from the phone's own preferences (`shared_preferences`), to import them. Nothing leaves the phone.

## Why the app needs Bluetooth

Bluetooth is how the app finds and controls your lights. There is no other way it reaches them.

- **iOS:** `NSBluetoothAlwaysUsageDescription`: "ElectroBright uses Bluetooth to find and control your lights."
- **Android 12+:** `BLUETOOTH_SCAN` (declared `neverForLocation`) and `BLUETOOTH_CONNECT`.
- **Android 11 and older:** location permission (`ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`, capped at SDK 30). Android requires it for Bluetooth scanning on those versions. The app never reads your location.
- **Vibration** (`VIBRATE`) for the haptic ticks on sliders.

## What the lights store

Each light keeps, in its own flash memory:

- its fixture type;
- its current look (colour, brightness, effect and effect settings);
- the sound on/off setting;
- its 15 preset looks (without names).

A light stores nothing about your phone or you. It has no internet connection and no clock.

## What was verified, and how

Checked in the code on 2026-09-30:

- **Dependencies:** `app/pubspec.yaml` lists only `flutter_reactive_ble`, `flutter_riverpod`, `liquid_glass_widgets`, `path_provider`, `shared_preferences`, `intl`, `collection`, `meta`, `cupertino_icons` and the Flutter SDK. A search of `app/pubspec.lock` (all 92 packages, including transitive ones) found no HTTP, Firebase, Sentry, analytics, URL-launching or connectivity package.
- **Network code:** a search of `app/lib` for `HttpClient`, `Socket`, `WebSocket`, `Uri.parse` and `launchUrl` found no uses.
- **Internet permission:** the release Android manifest (`app/android/app/src/main/AndroidManifest.xml`) has no `INTERNET` permission. Only the debug and profile manifests add it, which Flutter needs for development tools.
- **Logging:** the one `developer.log` call in `app/lib` (`sessions/connection_manager.dart`) runs inside an `assert`, so only in debug builds, and only to the local device log. Bluetooth tracing is also debug-only (commit de2545d).
- **Storage:** every store read and write goes through `JsonStore` or the one-time `shared_preferences` import.

Not verified: the behaviour of the operating system and third-party packages beyond their source not using the network. The iOS privacy manifest is `app/ios/Runner/PrivacyInfo.xcprivacy`; see [release.md](release.md).
