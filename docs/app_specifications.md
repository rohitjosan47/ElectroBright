# ElectroBright Mobile App Feature Specification

This document outlines every feature, control, and UI element required for the ElectroBright Flutter app. This directly mirrors the capabilities of the ESP32-C3 firmware (Protocol Version 2.6.0).

---

## 1. Global & Connection Controls
These elements should be accessible regardless of the current lighting mode.

*   **BLE Connection Manager**
    *   **Button/Icon:** Connect / Disconnect.
    *   **Graphic/Indicator:** Connection status (Scanning, Connected, Disconnected, Reconnecting).
    *   **Function:** Scans for devices named `ElectroBright_BLE` and binds to the Nordic UART Service (NUS).
*   **Power Control (Sleep Mode)**
    *   **Large Button:** Power On / Off.
    *   **Function:** Sends the `SLEEP` command to turn off LEDs, or sends a command (like restoring mode/color) to wake up.
*   **Global Brightness**
    *   **Slider:** 0% to 100% (Maps to 0-255).
    *   **Function:** Scales the overall brightness of the fixture.
*   **Hardware Settings**
    *   **Toggle Switch:** Sound (Buzzer) ON / OFF.
    *   **Button:** Factory Reset (Requires a confirmation dialog).
*   **Sleep Timer**
    *   **Time Picker/Slider:** 0 to 120 minutes.
    *   **Buttons:** Start Timer, Cancel Timer.
    *   **Graphic:** Countdown indicator showing remaining time until sleep.

---

## 2. Core Color Controls (The Palette)
These controls are active in Solid Mode (Mode 1) and dictate the base colors for many effect modes.

*   **RGB Color Wheel or Picker**
    *   **Graphic:** Interactive 2D color wheel or palette to pick Red, Green, and Blue hues.
*   **Individual Channel Sliders (RGBW)**
    *   **Slider:** Red (0-255)
    *   **Slider:** Green (0-255)
    *   **Slider:** Blue (0-255)
    *   **Slider:** True White (0-255) - Crucial for the 4th LED channel (RGB**W**).
*   **Function:** Sends `COLOR:<R>,<G>,<B>,<W>` or `BRIGHTNESS:<val>` commands.

---

## 3. Lighting Modes (Effects Engine)
A scrollable list, grid, or carousel of 13 selectable modes. When a mode is selected, contextual controls (Speed, Frequency, Color Toggles) will dynamically appear based on the mode's `MODE_CAPABILITIES`.

### Standard Modes
*   **Mode 1: Solid Color** (Capabilities: None. Relies entirely on the Core Color Controls).
*   **Mode 2: Blink** (Capabilities: Freq).
*   **Mode 3: Breath** (Capabilities: Freq).
*   **Mode 5: TV Simulator** (Capabilities: Speed, Freq).
*   **Mode 6: Thunderstorm** (Capabilities: Speed, Freq).
*   **Mode 7: Faulty Bulb** (Capabilities: Speed, Freq).
*   **Mode 8: Single Dynamic** (Capabilities: Freq).
*   **Mode 10: Rainbow** (Capabilities: Freq).
*   **Mode 11: Fire** (Capabilities: Speed, Freq).
*   **Mode 13: Candle** (Capabilities: Speed, Freq).

### Advanced Modes (With Custom Color Modifiers)
*   **Mode 4: Fireworks**
    *   **Toggle Switch:** Color Mode (Auto / Manual).
    *   *Auto:* Random firework colors. *Manual:* Uses Core Color Controls.
*   **Mode 9: Club Lights**
    *   **Toggle Switch:** Color Mode (Auto / Manual).
    *   *Auto:* Random club palette hits. *Manual:* Uses Core Color Controls.
*   **Mode 12: Police Strobe**
    *   **Toggle Switch:** Color Mode (Auto / Manual).
    *   *Auto:* Classic Red and Blue wig-wag.
    *   *Manual:* Reveals **Two Custom Color Pickers** for `POLICE_COLOR_A` and `POLICE_COLOR_B`. Allows the user to set the exact two colors to strobe between.

### Contextual Controls (Dynamic UI)
Depending on the active mode, these sliders appear:
*   **Speed Slider:** 1 to 10 (Controls `SPEED:<val>`).
*   **Frequency/Intensity Slider:** 1 to 10 (Controls `FREQUENCY:<val>`).

---

## 4. Presets & Memory
Allows the user to save their favorite combinations (Color + Mode + Speed + Freq + Modifiers).

*   **Preset Grid (15 Slots)**
    *   **Buttons:** 15 distinct slots.
    *   **Graphic:** If a slot is empty, show a "+" or "Empty" style. If occupied, show a colored icon representing the saved state.
*   **Preset Actions**
    *   **Save Button:** Overwrites a specific preset slot with the current live state.
    *   **Load Button:** Recalls a preset (Sent via `PRESET_LOAD:<id>`).
    *   **Delete/Trash Button:** Clears a preset slot.

---

## 5. Sync & Status Engine (Invisible to User)
The app must run a background listener to keep the UI in perfect sync with the hardware.

*   **Status Listener:** Parses incoming `STATUS:...` packets to instantly update UI sliders, toggles, and color wheels if the device changes state (e.g., if a preset is loaded).
*   **Settings Sync:** On connection, the app will send `MODE_SETTINGS` to fetch the background speeds and frequencies of all 13 modes to populate the UI.
