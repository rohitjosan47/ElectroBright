# Changelog

Newest first. User-visible changes in plain words, from `git log` and the firmware golden changelog (the comment at the top of `firmware/test/golden/Scenarios.cpp`). All dates are 2026. The app has been version 2.0.0 (`app/pubspec.yaml`) since the rebuild started, so app entries are grouped by the firmware they shipped with. Design reasons are in [docs/design_decisions.md](docs/design_decisions.md).

## App 2.0.0 with firmware 3.8.1 (28 Sep)

**App**
- Home shows only your own lights. Nearby lights appear as a count on **Add light**; the add screen lists them, with **Not mine** to hide one and a section for unsupported lights.
- **Wireless firmware updates** from the app: an update badge, progress with time left, Cancel until the image has arrived, automatic resume after a dropped link, and a clear message if the light rolled back.
- **Developer tools** (Settings → Advanced, off by default): change a light's fixture type, **Find the right type** by lighting each output, reinstall firmware, a debug-only rollback test, and Diagnostics in plain words.

**Firmware 3.8.1**
- The task watchdog is reconfigured instead of initialised a second time (the Arduino core already starts it).
- Rollback test images can be built for testing (never shipped in release apps).

## Firmware 3.8.0 (28 Sep)
- Wireless updates: two update slots, verified image (SHA-256 and identity), no downgrades, a 15 s self-check after restart and automatic rollback if it fails. Diagnostics show the running slot and whether the last update rolled back.

## Firmware 3.7.0 (28 Sep)
- One universal firmware for every light type; the light stores its type. New commands to change the type and to test each output; a light with no type starts in setup-needed mode. A factory reset keeps the type.

## Firmware 3.6.2 (28 Sep)
- Full brightness is truly 100 %: the output is held on instead of pulsed. In 3.6.1 lights went dim at exactly 100 % and effect peaks glitched.

## App 2.0.0 with firmware 3.6.1 (26–28 Sep)

**App**
- **Groups:** automatic Colour lights and White lights groups with a Home card, shared power, brightness, colour or temperature, effects and sleep timer; per-light level trim; "Own settings" for a light changed on its own; rejoining applies the group's look; 15 group presets kept on the phone.
- Identify, re-connecting while adding a light, a fresher nearby list, unsupported lights listed, Police on white lights, and cleanup fixes.
- Default names are unique ("RGBW light 2").
- Battery and heat: nothing redraws when nothing changes, the fast scan runs only when needed, iPhones capped at 60 Hz, high refresh on Android only while something moves.
- Look: frosted brand-glass sliders, liquid tiles, a real-looking rainbow glyph, luminous light theme; the colour display follows your finger.

**Firmware 3.6.1**
- Silent: the lights pulse at 25 kHz, so power supplies no longer whine (was 4.9 kHz).
- Smooth colour-temperature sweep on tunable-white lights.
- New **Identify**: two crisp flashes and one chirp.

## App 2.0.0 with firmware 3.6.0 (25 Sep)
- Firmware: 15 preset slots (was 25); old presets are wiped once on first start.
- App: rebuilt from scratch for iOS and Android. It drives all five light types (RGBW, RGB, RGBCCT, CCT, W) with controls built from what each light reports; demo lights; imports saved lights from the old app once; presets, sleep timer and sound; light settings with channel test. The original app was removed (tag `old-app-final`).

## Firmware 3.5.0 (24–25 Sep)
- Firmware family: one shared core and a sketch per light type. New fixtures: RGB, RGBCCT, tunable white (CCT) and single white (W).

## Firmware 3.4.0 (24 Sep)
- Ground-up rewrite of the RGBW firmware; its behaviour is the golden baseline (tag `fw-3.4.0-golden`).

## Before 3.4.0
- Firmware 2.7.x and the original Flutter app: binary fast path for colour streaming, module split, saved app state and reconnect backoff. Not supported by the current app (it shows "Firmware update needed").
