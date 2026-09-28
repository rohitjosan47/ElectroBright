# ElectroBright documentation

ElectroBright is a Bluetooth lighting system with three parts. ESP32-C3 controllers drive 12 V / 24 V LED strips of five fixture types (RGBW, RGB, RGBCCT, CCT, W). All of them run one universal firmware (3.8.2). A Flutter app for iOS and Android (2.0.0) controls them directly from the phone, with no server or cloud. This page lists every document, who it is for and what it covers.

## Documents

| Document | Audience | What it's for |
|---|---|---|
| [user_guide.md](user_guide.md) | People using the lights | How to add, control, group and update lights; FAQ |
| [privacy.md](privacy.md) | Users, app-store review | What the app stores (on the phone only) and what it doesn't collect |
| [troubleshooting.md](troubleshooting.md) | Users, developers | Symptom → cause → fix; every Diagnostics field |
| [limitations_and_roadmap.md](limitations_and_roadmap.md) | Everyone | Known limits, planned work, and what isn't planned |
| [app.md](app.md) | Developers, testers | Every app feature and control per light type; code layout |
| [architecture.md](architecture.md) | Developers | System, app and firmware layers; connections, groups, update pipeline |
| [design_decisions.md](design_decisions.md) | Developers | Why things are built this way, what was rejected, and when |
| [protocol.md](protocol.md) | App and firmware developers | The Bluetooth contract every light implements |
| [../firmware/README.md](../firmware/README.md) | Firmware developers | Firmware reference: fixtures, architecture, modes, tests, DIAG |
| [firmware.md](firmware.md) | Firmware developers, makers | Building, flashing, update images, versioning |
| [../app/README.md](../app/README.md) | App developers | Short entry point for the app folder |
| [testing.md](testing.md) | Developers | Every automated suite, and the hardware checklists |
| [release.md](release.md) | Maintainers | Release procedure for the app stores and firmware |
| [security.md](security.md) | Maintainers | The current security state and planned work |
| [wiring_guide.md](wiring_guide.md) | Makers | Circuit, parts and pinout for every fixture |
| [backup_power.md](backup_power.md) | Makers | Keeping the controller alive through short power cuts |
| [../CHANGELOG.md](../CHANGELOG.md) | Everyone | App and firmware history, newest first |

## Reading order for a new developer

1. [architecture.md](architecture.md) for the big picture.
2. [design_decisions.md](design_decisions.md) for the reasons behind it.
3. [app.md](app.md) and [../firmware/README.md](../firmware/README.md) for each side in detail.
4. [protocol.md](protocol.md) for the wire contract between them.
5. [testing.md](testing.md), then [firmware.md](firmware.md) to build and flash a light.
6. [release.md](release.md) and [security.md](security.md) before shipping anything.

## Glossary

| Term | Meaning |
|---|---|
| Fixture | One light: an ESP32-C3 controller driving an LED strip. |
| Type / layout | Which LED channels a fixture has: RGBW, RGB, RGBCCT, CCT or W. The light stores its type (`SET_TYPE`); the layout is the channel order on the wire. See [protocol.md](protocol.md). |
| Group | The automatic set of your lights of one kind: **Colour lights** (RGB, RGBW, RGBCCT) or **White lights** (CCT, W). See [app.md §3](app.md#3-groups). |
| Trim | "Level in group": a light's share of the group brightness, 5–100 %. |
| Own settings | A light that followed the group and was then changed on its own screen. Group commands skip it until it rejoins. |
| Preset | A saved look. Each light has 15 preset slots in its own memory. Each group has 15 group presets, stored on the phone. |
| DIAG | The firmware's diagnostics reply, shown in plain words under Developer tools. See [troubleshooting.md](troubleshooting.md). |
| Update slot | One of the two firmware partitions in the light's 4 MB flash. An update is written to the slot that isn't running. |
| Rollback | If new firmware fails its self-check after an update, the light restarts into its previous slot on its own. |
| Demo mode | Simulated lights (one of every type) that run a copy of the firmware logic, so you can try the app without hardware. |
