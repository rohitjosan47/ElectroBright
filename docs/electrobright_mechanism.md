# ElectroBright ESP32-C3 BLE - System Mechanism & Communication Protocol

This document outlines the complete working mechanism of the `ElectroBright_ESP32C3_BLE.ino` firmware. It is intended as a reference for developing an Android/iOS companion app that interfaces with the hardware via Bluetooth Low Energy (BLE).

## 1. Hardware Configuration
The system controls a 4-channel RGBW LED strip using PWM, provides acoustic feedback via a buzzer, and uses the onboard LED for status indication.

*   **Red LED:** GPIO 2 (PWM)
*   **Green LED:** GPIO 3 (PWM)
*   **Blue LED:** GPIO 4 (PWM)
*   **White LED:** GPIO 5 (PWM)
*   **Buzzer:** GPIO 6 (PWM)
*   **Status LED (Yellow-Green):** GPIO 7 (PWM)
*   **Status LED (Red):** GPIO 8 (PWM)

### Dual-Color Status LED Behavior
The system uses a common-anode dual-color LED (Red + Yellow-Green) for hardware status indication, operating independently of the main lighting:

| Color | State | Meaning |
| :--- | :--- | :--- |
| **Yellow-Green** | Breathing (2s cycle) | Actively advertising (waiting for a BLE connection). |
| **Yellow-Green** | 2 Quick Blinks | A BLE client has successfully connected. |
| **Red** | Brief Breathing Pulse | A lighting mode change was successfully parsed and applied. |
| *(Off)* | Off | Connected and idle, or the system is in sleep mode. |

## 2. Core Architecture
The firmware operates on a non-blocking asynchronous architecture. The `loop()` function continuously:
1.  Resets the watchdog timer.
2.  Reads incoming Bluetooth serial data.
3.  Calculates and applies the current LED frame (handling smooth transitions and active effects).
4.  Processes buzzer audio events.
5.  Evaluates active sleep timers.
6.  Commits state changes to EEPROM if a delay threshold has passed.

### State Management
The device maintains a `SystemState` which dictates its behavior. This state is backed by EEPROM (saved automatically 5 seconds after a change) and includes:
*   `red`, `green`, `blue`, `white`: Current base colors (0-255)
*   `brightness`: Global brightness scalar (0-255)
*   `mode`: Current lighting effect mode (1-13)
*   `modeSpeed[13]`: Effect speed multiplier (1-10) stored independently per mode
*   `modeFrequency[13]`: Effect frequency parameter (1-10) stored independently per mode
*   `fireworkColorMode`: Fireworks color mode — 0 = MANUAL (uses current RGBW color), 1 = AUTO (picks random firework hues)
*   `clubColorMode`: Club Lights color mode — 0 = MANUAL (uses current RGBW color), 1 = AUTO (picks random club-palette hues)

EEPROM is protected against corruption using a CRC8 checksum and a Magic Byte (`0xEB09`). Old structs (Magic Bytes `0xEB05`, `0xEB06`, `0xEB07`, and `0xEB08`) are automatically migrated.

## 3. Lighting Modes
The system supports 13 distinct lighting modes.
*   **Mode 1:** Static Color (Solid RGBW)
*   **Mode 2:** Blink
*   **Mode 3:** Breath (Easing sine-wave pulse)
*   **Mode 4:** Fireworks (5-state time-domain simulator: idle → rising glow → burst flash → crackle decay → afterglow)
*   **Mode 5:** TV Simulator (Cinematic scene changes)
*   **Mode 6:** Thunder Simulator (Lightning flashes with easing decay)
*   **Mode 7:** Faulty Bulb (Weighted fault simulator: steady with subtle ripple → random faults including quick flicker-outs, full dropouts with struggling restart, sputtering dim spells, and rare arc double-flashes)
*   **Mode 8:** Single Dynamic
*   **Mode 9:** Club Lights (Weighted hit-pattern selector: solid color slams, strobe bursts, color snap chains, blackout snaps, and white strobe flashes)
*   **Mode 10:** Rainbow
*   **Mode 11:** Fire (Wash-cycle and flare-up brightness simulator applied to base color)
*   **Mode 12:** Police (Accurate warning strobe simulator with Auto Red/Blue and Manual User-color modes)
*   **Mode 13:** Candle (Three-layer low-pass noise flicker with rare near-miss dip events)

## 4. Bluetooth Communication Protocol
The device uses Bluetooth Low Energy (BLE) via the Nordic UART Service (NUS).
*   **Format:** Plain text commands.
*   **Termination:** Every command sent from the Android app **must** be terminated with a newline (`\n`) or carriage return (`\r`).
*   **Responses:** The device generally responds with `OK` on success, or an `ERROR:<reason>` string on failure.

### Command Reference

#### Control Commands
| Command Format | Description | Constraints |
| :--- | :--- | :--- |
| `RGBW:<R>,<G>,<B>,<W>` | Sets the base color values. | Values: 0-255 |
| `BRIGHTNESS:<value>` | Sets the global brightness. | Value: 0-255 |
| `MODE:<id>` | Changes the active lighting effect. | ID: 1-13 |
| `SPEED:<value>` | Adjusts the speed of the **currently active** mode. | Value: 1-10 |
| `FREQUENCY:<value>` | Adjusts the frequency of the **currently active** mode. | Value: 1-10 |
| `MODE_SPEED:<m>,<s>` | Adjusts the speed of a specific mode `<m>` without making it active. | `m`: 1-13, `s`: 1-10 |
| `MODE_FREQUENCY:<id>,<value>` | Sets the frequency for a specific mode (1-10). | `OK` or `ERROR:MODE_FREQUENCY_INVALID` |
| `FIREWORK_COLOR_MODE:<0\|1>` | Toggles Mode 4 Fireworks colors (0=Manual base color, 1=Auto RGB random) | `OK` or `ERROR:FIREWORK_COLOR_MODE_INVALID` |
| `CLUB_COLOR_MODE:<0\|1>` | Toggles Mode 9 Club Lights colors (0=Manual base color, 1=Auto RGB cycles) | `OK` or `ERROR:CLUB_COLOR_MODE_INVALID` |
| `POLICE_COLOR_MODE:<0\|1>` | Toggles Mode 12 Police colors (0=Manual custom colors, 1=Auto Red/Blue) | `OK` or `ERROR:POLICE_COLOR_MODE_INVALID` |
| `POLICE_COLOR_A:<r>,<g>,<b>,<w>`| Sets the first custom color for Mode 12 Manual mode | `OK` or `ERROR:FORMAT` |
| `POLICE_COLOR_B:<r>,<g>,<b>,<w>`| Sets the second custom color for Mode 12 Manual mode | `OK` or `ERROR:FORMAT` |

#### Preset Commands
The system can save up to 15 user-defined presets into EEPROM.
| Command Format | Description | Constraints |
| :--- | :--- | :--- |
| `PRESET_SAVE:<id>` | Saves the current state to the specified slot. | ID: 0-14 |
| `PRESET_LOAD:<id>` | Loads the state from the specified slot. | ID: 0-14 |
| `PRESET_DELETE:<id>`| Deletes the preset at the specified slot. | ID: 0-14 |

#### Utility & System Commands
| Command Format | Description | Device Response |
| :--- | :--- | :--- |
| `STATUS` | Requests the current system state. | `STATUS:<r>,<g>,<b>,<w>,<brightness>,<mode>,<active_speed>,<active_freq>,<fw_color_mode>,<cl_color_mode>,<pol_color_mode>` |
| `MODE_SETTINGS` | Requests all modes' stored speeds/frequencies. | `MODE_SETTINGS:<s1>,<f1>;<s2>,<f2>;...;<s13>,<f13>` |
| `MODE_CAPABILITIES:<id>` | Asks what controls a mode supports. | `CAPABILITIES:NONE` (mode 1), `CAPABILITIES:SPEED,FREQUENCY,COLOR_MODE` (modes 4, 9), or `CAPABILITIES:SPEED,FREQUENCY` (others) |
| `PRESET_LIST` | Requests a list of saved preset IDs. | `PRESETS:<id1>,<id2>,...` (e.g., `PRESETS:0,3,14,`) |
| `PING` | Connectivity check. | `OK` |
| `INFO` | Requests device firmware info. | `INFO:ElectroBright_ESP32C3_BLE` |
| `VERSION` | Requests device firmware protocol version. | `VERSION:2.6.0` |
| `SLEEP` | Turns off the LEDs (soft power off). | `OK` |
| `TIMER:<minutes>` | Sets an auto-sleep timer. Send `0` to cancel. | `OK` |
| `SOUND_ON` | Enables the physical buzzer. | `OK` |
| `SOUND_OFF` | Disables the physical buzzer. | `OK` |
| `FACTORY_RESET` | Wipes EEPROM and restarts. | `OK` |

### Error Responses
If the device receives an invalid command or parameter, it responds with one of the following:
*   `ERROR:FORMAT` - Parsing failed (e.g., non-numeric characters in RGBW).
*   `ERROR:MODE_INVALID` - Mode out of bounds.
*   `ERROR:SPEED_OUT_OF_BOUNDS` - Speed out of bounds.
*   `ERROR:FREQUENCY_INVALID` - Frequency out of bounds.
*   `ERROR:MODE_SPEED_INVALID` - Specified mode or speed out of bounds.
*   `ERROR:MODE_FREQUENCY_INVALID` - Specified mode or frequency out of bounds.
*   `ERROR:FIREWORK_COLOR_MODE_INVALID` - Firework color mode value not 0 or 1.
*   `ERROR:CLUB_COLOR_MODE_INVALID` - Club color mode value not 0 or 1.
*   `ERROR:BRIGHTNESS_INVALID` - Brightness out of bounds.
*   `ERROR:PRESET_ID` - Preset slot out of bounds.
*   `ERROR:PRESET_EMPTY` - Tried to load a preset slot that is empty.
*   `ERROR:PRESET_DELETE` - Deletion failed.
*   `ERROR:UNKNOWN_CMD` - Unrecognized command string.

## 5. Development Notes for Android App
1.  **Throttling Slider Data:** The `RGBW:` command is highly optimized to not trigger EEPROM writes or block the effect loop. It is safe to stream `RGBW:` commands rapidly (e.g., from a color wheel on drag), but it's still recommended to throttle sending to ~50ms to prevent buffer overflow (the device buffer is 64 bytes).
2.  **Initial Sync:** Upon connecting via BLE, the companion app should send the `STATUS` command to sync its UI with the physical device's current state.
3.  **Presets Sync:** After a connection, the app should also send `PRESET_LIST` to know which preset slots are currently occupied so it can render the UI appropriately.
4.  **Audio Feedback:** The device provides physical buzzer feedback for different events (errors, modes changes, saves). The app can control this via `SOUND_ON` and `SOUND_OFF`.
