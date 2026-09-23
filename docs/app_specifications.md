# ElectroBright Mobile App — Feature Specification

This document describes every feature, control and UI element of the ElectroBright Flutter app (`electrobright_app/`). It mirrors the capabilities of the ESP32-C3 firmware in `firmware/ElectroBright/`. The byte-level BLE protocol is documented in the [firmware README](../firmware/ElectroBright/README.md#4-ble-protocol-nordic-uart-service).

---

## 1. Global & Connection Controls
These are available regardless of the current lighting mode.

*   **My Lights (device library)**
    *   Add a light: scan → connect → identify (`INFO`) → name it.
    *   For each saved light: connect / disconnect, rename, change type, remove (which also deletes that light's saved preset names).
    *   Scanning finds devices whose name starts with `ElectroBright_C3_` (the firmware advertises `ElectroBright_C3_V1`) or the legacy `ElectroBright_BLE`, offering the Nordic UART Service.
    *   Connection status in the header: Scanning, Connecting, Connected, Reconnecting (n/3), Disconnected.
    *   After an unexpected link loss the app reconnects automatically (3 attempts, backing off 1 s / 2 s / 4 s).
*   **Power (sleep)**
    *   Header button sends `SLEEP` / `WAKE`. The light fades out/in in every mode.
    *   Sleeping also cancels a running sleep timer.
    *   The button is disabled with a message while no light is connected.
*   **Master brightness**
    *   Slider 0–100 % (0–255), perceptually uniform.
*   **Hardware settings**
    *   Sound (buzzer) on/off — remembered by the light.
    *   Firmware version.
    *   Transport drop counter.
    *   Factory reset — with confirmation; erases the light's presets and settings.
*   **Sleep timer**
    *   Steps from 30 s to 6 h, with Start / Cancel.
    *   A live countdown is shown.
    *   When it expires the light fades out and reports its new state to the app.

---

## 2. Core Colour Controls (the palette)
The base colour used by Solid Color and by every effect that follows the picked colour.

*   **Colour picker:** hue ring with an inner saturation/brightness square, plus a True White (W) slider.
*   **Channel sliders:** Red, Green, Blue, White (0–255 each).
*   **Transmission:**
    *   While dragging, the app streams the 8-byte binary colour packet (colour + brightness) at up to ~33 Hz.
    *   On release, the final value is sent with a write response so it cannot be lost.
    *   Older firmware without binary support receives `RGBW:<r>,<g>,<b>,<w>` / `BRIGHTNESS:<n>` text commands instead.
*   The light smooths colour and brightness changes itself, so dragging looks continuous on the hardware.

---

## 3. Lighting Modes
A carousel of 13 modes. Selecting a mode shows only the sliders that mode supports. Each slider is named after what it actually does in that mode.

These names come from `ModeDefinition` (`lib/features/dashboard/domain/mode_definition.dart`). The test `test/mode_registry_sync_test.dart` checks them against the firmware's `src/render/ModeRegistry.h`.

| # | Mode | Speed slider | Frequency slider | Colour option |
|---|---|---|---|---|
| 1 | Solid Color | — | — | — |
| 2 | Blink | — | Blink Rate | — |
| 3 | Breath | Breath Shape | Breathing Rate | — |
| 4 | Fireworks | Burst Speed | Launch Rate | Auto palette / picked colour |
| 5 | TV Simulator | Scene Pace | Cuts & Flicker | — |
| 6 | Thunderstorm | Stroke Tempo | Strike Rate | — |
| 7 | Faulty Bulb | Glitch Speed | Glitch Rate | — |
| 8 | Welding | Weld Length | Weld Gap | — |
| 9 | Club Lights | Tempo | Energy | Auto palette / picked colour |
| 10 | Rainbow | — | Cycle Speed | — |
| 11 | Fire | Flicker Speed | Flame Intensity | — |
| 12 | Police Strobe | Flash Speed | Flashes per Side | Red & Blue / two custom colours (A, B) |
| 13 | Candle | Flicker Speed | Flicker Depth | — |

Both sliders range from 1 to 10. They are sent as `SPEED:<n>` / `FREQUENCY:<n>` and apply to the active mode; each mode remembers its own values. Changes take effect on the light immediately.

---

## 4. Presets
A preset saves the whole scene: colour, brightness, mode, every mode's slider values, colour options and police colours.

*   **25 slots**, stored on the light. A new or factory-reset light has no presets.
*   **Actions:**
    *   Save — overwrites the slot with the current scene.
    *   Load.
    *   Delete.
    *   Rename — names are stored in the app, per light.
*   Loading a preset wakes the light and keeps the current mute setting. Sound is a device setting, not part of a scene.

---

## 5. Sync & Status (invisible to the user)
*   **On every connection** the app requests `STATUS`, `MODE_SETTINGS`, `PRESET_LIST`, `VERSION` and `CAPS`.
*   **STATUS is authoritative.** It carries colour, brightness, mode, the active mode's sliders, colour options, sleep and timer state, sound and police colours. The app applies it to every control.
*   **While the user is dragging** a control, incoming echoes for that control are held back briefly, so the slider never jumps back under the finger.
*   The light pushes a `STATUS` on its own when the sleep timer expires.
