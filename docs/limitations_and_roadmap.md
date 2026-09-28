# Limitations and Roadmap

As of app 2.0.0+200 and firmware 3.8.1. How things work today is in [architecture.md](architecture.md); why, in [design_decisions.md](design_decisions.md).

## Known limitations

| Limit | Detail |
|---|---|
| Bluetooth connections per phone | The app connects at most 8 lights at once on iOS and 5 on Android, favourites first. Others in an open group show "Phone limit". See [architecture.md](architecture.md). |
| Effects drift apart | Groups broadcast the same command, but each light runs its own effect clock. Two lights running Rainbow are not in step. |
| Updates need the app | A wireless update runs only while the app is open and the phone stays in Bluetooth range. Only one light updates at a time. See [app.md §4b](app.md#4b-wireless-firmware-updates). |
| No clock in the lights | A light only knows time since power-on, so there are no schedules, sunrise alarms or time-of-day behaviour. The sleep timer is a countdown. |
| Offline changes | Changes made while a light reconnects wait 60 s and are not kept across app restarts. |
| Android | Built and tested with simulated Bluetooth only; not yet verified on a real Android phone. |
| Security | Anyone in Bluetooth range can connect and send any command, including a type change or an update. Update images are not signed. See [security.md](security.md). |

## Roadmap (proposed)

Nothing below is built or scheduled. Items are grouped by what they need.

**App only**
- **Scenes on Home:** one tap applies a saved look to several lights.
- **Colours from a photo:** pick a palette from a picture.
- **Backup and restore:** export saved lights, names, groups and presets, and bring them back on a new phone.

**Firmware and app**
- **Power-on behaviour:** choose what a light does when its power returns (last look, a preset, or off).
- **Fade-to-sleep:** the sleep timer dims slowly over its last minutes instead of switching off.
- **Music sync** as an optional mode.
- **Firmware signing and ownership:** signed update images and pairing, so only the owner's phone can change a light. Required before a public release; see [security.md](security.md).

**Needs a clock in the lights**
- **Sunrise wake-up, schedules and natural light** (colour temperature following the time of day).

**Needs a light network**
- **ESP-NOW mesh** between lights: control many lights beyond the phone's connection limit, and run synchronised effects on a shared clock.

## Deliberately not planned

| Idea | Why not |
|---|---|
| Automatic on when you arrive home | Needs background location or constant scanning; costs battery and privacy for little gain. |
| Voice assistants and Matter | Needs Wi-Fi, a hub or cloud accounts, against the Bluetooth-only, no-server design ([design_decisions.md](design_decisions.md)). |
| More effects | 13 effects already cover the range; effort goes to quality and the items above instead. |
