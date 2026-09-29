# Troubleshooting

## 1. Symptoms

| Symptom | Likely cause | Fix |
|---|---|---|
| Stuck on **Connecting…** after flashing new firmware | The app on the phone is older than the firmware, or the phone cached the light's old Bluetooth services. | Reinstall the app from the same commit as the firmware so they match. If it persists, turn Bluetooth off and on (iOS: Settings, not Control Centre). *The exact mechanism is from experience, not reproduced in a test.* |
| Light shows **Needs a newer app version** | The firmware reports a layout the app doesn't know. | Update the app. |
| Light shows **Firmware update needed** / is under **Unsupported** | Pre-3.x firmware. | Flash current firmware over USB ([firmware.md](firmware.md)). |
| Light not found on the add screen | Off, out of range, connected to another phone (only one phone at a time), or hidden as **Not mine**. | Power it, come closer, close the app on other phones, tap **Show hidden lights**. Lights appear only after an advert in the last 10 s. |
| **Unavailable** on Home | Same as above; a lost link retries with backoff (0.5 s up to 30 s). | Wait, or open the light to retry now. |
| **Bluetooth is off** | Phone setting. | Android: **Turn on Bluetooth** on the notice. iOS: Control Centre or Settings. |
| **Bluetooth permission needed** | The app's Bluetooth permission was refused. | **Open settings** on the notice and allow Bluetooth (Android 12+: "Nearby devices"; Android 11 and older: location). |
| **Location Services are off** | Android 11 and older need them to find Bluetooth lights. | **Open settings** on the notice and switch Location on. The app never reads your location. |
| **Bluetooth not supported** | The device has no Bluetooth Low Energy. | Only demo lights work on it. |
| **Setup needed** on a tile | 3.7.0+ firmware with no stored type. | Open it → **Find the right type** → choose the type. |
| Wrong controls for a light (e.g. colour wheel on a white strip) | The stored fixture type doesn't match the wiring. | Settings → Advanced → Developer tools on, then the light's **Developer** page → **Find the right type** → **Change type**. Presets are cleared. |
| Update failed | See the message: the light keeps its firmware in every case before install. Link lost or stalled → move closer and tap **Update** again; it resumes. "Couldn't save" → power-cycle the light first. "Damaged in this app" → reinstall the app. | |
| **The update didn't take; your light is back on its previous firmware** | The new firmware failed its 15 s self-check (or crashed/froze) and the bootloader rolled back. | Check Diagnostics (`rst`, `rb=1`). Try again; if it repeats, flash over USB and report it. |
| **Another light is updating** | Only one update at a time. | Wait. |
| Group says **This phone can connect N lights at once** | Connection limit: 8 on iOS, 5 on Android, favourites first. | Mark the lights you need as favourites. See [architecture.md](architecture.md). |
| A group light ignores group changes | It is on **Own settings** or excluded. | Turn its switch on, or **Rejoin all**. |
| Changes you made while a light was away didn't arrive | Offline changes wait at most 60 s and aren't kept across app restarts. | Make the change again once it is connected. |
| Lights look real but nothing physical changes | Demo mode (the **Demo** badge). | Settings → **Use my real lights**. **Try demo lights** switches back. |
| Buck converter whines | Firmware older than 3.6.1 (4.9 kHz PWM). | Update firmware. |

## 2. Diagnostics

Settings → Advanced → Developer tools → a light → **Diagnostics** shows the firmware's `DIAG` reply (`app/lib/features/developer/diag_report.dart`). Counters reset at every restart. The field list is also in [firmware/README.md §7](../firmware/README.md#7-diagnostics-diag).

"Healthy" below is derived from the code and constants (`firmware/core/ElectroBrightCore/src/config/Config.h`), not from measured field data.

### Summary

| Field | Meaning | Healthy |
|---|---|---|
| `up` | Uptime in seconds. | Grows; a small value you didn't cause means a restart. |
| `rst` | Last restart reason (below). | Power on, software, or USB. |
| `slot` | Firmware slot running (0 or 1, 3.8.0+). | Changes after each successful update. |
| `rb` | 1 if a rollback has happened since that slot was last written (3.8.0+; the next install clears it). | 0. |
| `pv` | 1 while a newly installed firmware has not confirmed itself yet (3.8.2+). | 0 after a few seconds. |
| `endms` | The last update's final check (END to `END_OK`), ms; 0 when none recorded (3.8.2+). | Any. |

### Counters

| Field | Meaning | Healthy |
|---|---|---|
| `frames` | Frames rendered (200 Hz). | ≈ 200 × `up`. |
| `overrun` | Missed frame ticks. | 0 or a few. |
| `rmaxus` | Slowest frame, µs. | Well under 5000 (the frame period). |
| `rx` | Text lines received. | Any. |
| `bin` | Binary colour frames accepted. | Any. |
| `gaps` | Binary sequence gaps (lost packets). | Low; grows with weak signal. |
| `binbad` | Binary frames with a bad checksum. | 0. |
| `unk` | Unknown commands. | 0 with a matching app. |
| `err` | Rejected commands. | Low. |
| `coal` | Lines superseded by a newer one before running. | Any (normal while dragging). |
| `ovf` | Over-long lines dropped. | 0. |
| `rej` | Garbage lines dropped. | 0. |
| `sdrop` | Writes dropped, receive stream full. | 0 or low. |
| `nretry` | Notify retries (Bluetooth stack busy). | Low. |
| `edrop` | Reply lines dropped (buffer full). | 0. |
| `heapmin` | Lowest free heap since boot, bytes. | Not verified; watch for a value that shrinks across long sessions. |
| `stkc` | Control task stack headroom, bytes (of 8192). | Above ~1000 (rule of thumb, not verified). |
| `stkr` | Render task stack headroom, bytes (of 4096). | Above ~500 (rule of thumb, not verified). |
| `nvsw` | Flash writes. | Grows with saves, not continuously. |
| `nvsf` | Flash write failures. | 0. A failure also sends `ERROR:STORAGE` once per boot. |

Keys the app doesn't know appear under **Other**.

### Restart reasons (`rst`)

The ESP-IDF `esp_reset_reason_t` value.

| Code | Shown as | Meaning |
|---|---|---|
| 0 | Unknown | Not determined. |
| 1 | Power on | Normal power-up. |
| 2 | Reset pin | The board's reset button or pin. |
| 3 | Software | A deliberate restart: after SET_TYPE or an update (a factory reset does not restart the light). |
| 4 | Crash | Exception/panic. Report it. |
| 5 | Interrupt watchdog | An interrupt handler hung. Report it. |
| 6 | Task watchdog | A task stopped running (also the **Freezes** rollback test). |
| 7 | Other watchdog | Another watchdog. Report it. |
| 8 | Deep sleep | Not used by this firmware. |
| 9 | Brownout | Supply voltage dipped: check the buck converter and wiring ([backup_power.md](backup_power.md)). |
| 10 | SDIO | Not used. |
| 11 | USB | Reset over USB (e.g. flashing). |
| 12 | JTAG | Debugger reset. |
| 13 | eFuse | eFuse error. |
| 14 | Power glitch | Supply glitch: check power. |
| 15 | CPU lockup | CPU locked up. Report it. |
