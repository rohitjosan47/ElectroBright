# ElectroBright App

The Flutter app in `app/` (version 2.0.0, build 200, in `app/pubspec.yaml`; iOS and Android) controls every ElectroBright fixture over Bluetooth Low Energy. It reads what each light's firmware can do and builds its controls from that. The wire contract is in [protocol.md](protocol.md); the layers are in [architecture.md](architecture.md) and the tests in [testing.md](testing.md).

## 1. Lights and connection
- **Home** lists your saved lights ("3 of 5 connected"); it never lists nearby lights. With no saved light it shows a short welcome, **Add your first light**, pointing to the **Add light** button. Each tile has:
  - a colour orb, the name, the **type badge** (e.g. "Tunable white" with one dot per LED) and a state line such as "On · 80 % · Fire";
  - a presence line (Connected, Connecting…, or Unavailable: off, out of range, or connected to another phone) and a power button.
  - Long-press a tile for Rename, Identify, Light settings or Forget. Identify on a light that isn't connected says "Connecting…", connects it and then identifies it; after 10 s it gives up and says so. Tapping it again meanwhile does nothing more.
- **Nearby badge:** the **Add light** button carries a count of the lights nearby that can be added: not saved, not on the original firmware, not hidden as **Not mine**, and heard in the last 10 s of scanning. There is no badge at 0; a screen reader says "Add light, 2 lights nearby". For it, Home runs a low-power scan filtered to the ElectroBright service, only while Home is on screen and the app is in the foreground.
- **Nearby lights** are listed on the add screen, with their type read from the Bluetooth name: only lights heard in the last 10 s of scanning. A light appears with its first advert and leaves 10 s after its last one (so it doesn't flicker); when the scan starts again, nothing from before is shown until it is heard again. Lights are forgotten entirely after 2 minutes of scanning without an advert. The add screen runs the fast, unfiltered scan, only while it is open (so it also finds lights on the original firmware, which may not advertise the service).
  - **Not mine** on a nearby light hides it from the list and the badge. The app remembers it by device id (demo lights apart from real ones). **Show hidden lights**, at the bottom, brings every hidden light back.
  - **Unsupported lights**, at the bottom of the add screen, lists lights on the original firmware ("These lights run older firmware this app no longer supports."), with the same 10 s rule; they are never in the nearby list or the badge. Tapping one opens the firmware update screen.
- **Add a light** (tap a nearby light on the add screen) has these steps:
  1. The app connects and reads the light's identity ("Found a Tunable white light · firmware 3.6.0").
  2. **Flash it** identifies the light so you can find it.
  3. You name it.
  4. Save. Nothing is saved until Save, and Cancel always disconnects.
- **Connection:**
  - Lights you open are connected, plus up to three favourite or recent lights while Home is open.
  - A dropped link reconnects on its own.
  - Changes made while a light is unreachable wait for it for 60 s (`FixtureSession.offlineWindow`) and are sent when it is back; after that they are dropped and the controls return to the light's real values. They are kept in memory only, so an app restart drops them.
  - In the background every light is released after 20 s.
- **Demo lights** (onboarding, or Settings on Home): one simulated light of every type plus one on the original firmware. They run a copy of the firmware logic.
- **Reflashed as another type:** a light reflashed as a different fixture type is detected on the next connect ("Kitchen is now a CCT light"). Its saved presets and last state are reset.
- **Setup needed:** a light whose firmware has no fixture type yet (3.7.0+, CAPS `LAYOUT=NONE`) shows "Setup needed" on its tile, with or without the developer tools. Tapping it opens only **Find the right type** and the type list (§4a). It is in no group until it has a type. The add flow saves such a light as "New light", marked as needing setup.
- **Old app data:** saved lights from the previous app are imported once, on the first launch. Presets are not: firmware 3.6.0 clears the presets on every light once, and the app drops its old preset names and looks once to match.

## 2. Control screen
It has a header (back, name, type badge, power), the orb (the running effect in the light's own colours), and a toolbar: **Timer**, **Sound** and **Light settings**.

**Brightness.** The slider gives a haptic tick every 10 %. Releasing at 0 turns the light off and remembers the previous brightness. Touching colour or brightness wakes a sleeping light.

**Tabs follow the light's colour surface:**

| Type | Tabs | Colour controls |
|---|---|---|
| W (single white) | Effects · Presets | None. The brightness slider is the light's **intensity**. If the channel is below full, a caption shows the real output ("Output 50 %"). **Use full range** moves it all onto the slider in one step, with no visible change. |
| CCT (tunable white) | White · Effects · Presets | **Colour temperature** across the LEDs' own range, and **Level**. |
| RGB | Colour · Effects · Presets | Colour wheel. |
| RGBW | Colour · Effects · Presets | Colour wheel and a **White LED** slider. |
| RGBCCT | Colour · Effects · Presets | **Colour \| White**. Colour is the wheel with the white LEDs off; White is temperature plus level with RGB off. A look that is neither shows as **Custom**. |

On every type except W, **Channels** shows each LED's exact 0–255 value in its own colour. The picker keeps what you chose (e.g. the hue at low saturation), so the light's rounded echo never moves the controls. When the running effect makes its own colours, a note offers **Switch to Solid**.

**Effects.**
- The tab shows only the modes the light supports: 13, or 12 on W, which has no Rainbow.
- Names and preview colours match the light. On CCT, Rainbow is "Temperature sweep" and TV plays in warm and cool whites.
- The selected mode shows only its own sliders, with the firmware's names (e.g. "Stroke Tempo").
- Fireworks, Club and Police have a colour-source toggle. It is worded per type: "Your colour / Auto palette", "Your white / Auto (warm & cool)" or "Your level / Auto flashes".
- Police beacons are picked with the light's own colour controls. On white-only lights (tunable white, single white) Police alternates two whites on its own: it has no colour source and no beacons.

**Presets.**
- The 15 slots on the light, with a preview in its colours; W shows the output %.
- Tap to load, tap an empty slot to save and name it, long-press to Load / Rename / Overwrite / Clear.
- "Current look: …" or "Modified from …" is shown above the slots.

**Timer.** A dial from 30 s to 24 h, with a live countdown under the toolbar.

**Sound.** Turns the light's buzzer on or off.

## 3. Groups
Every light belongs to exactly one of two automatic groups, by its LEDs:

- **Colour lights:** RGB, RGBW and RGB+CCT.
- **White lights:** tunable white (CCT) and single white (W).

A group exists with two or more lights, and new lights join their group on their own. Home shows one **Groups** card at the top: a half per group (**Colour lights** | **White lights**), each with its first lights' colours and "3 of 4 connected". With one group, it fills the card; with none, there is no card. The card connects nothing; it is the only way in. Only one group is open at a time.

- **Common controls:** power, brightness, effects (with their speed and frequency) and the sleep timer, sent at the same moment to every light that follows the group and can take them. When the lights differ, the controls say so ("Mixed", "Timers differ") until you set them all. A mixed brightness pill keeps showing the group's last brightness (full before the first one), never a value worked out from the lights.
- **Colour lights: Colour | Effects | Presets.** The Colour tab is the wheel alone. A pick goes to every light with its white LEDs off (RGBW's W, RGB+CCT's cool and warm white at 0), so all the lights match. The group sends no white or temperature.
  - Fireworks, Club and Police show their **Colours** source, and Police on "Your colours" shows beacons A and B, as on a single light. They go to every light whose firmware has the effect; beacon colours go with every white LED off. When the lights differ, no source is selected and the beacon swatch is split, until the first change sets them all.
- **White lights: White | Effects | Presets** (W lights only: Effects | Presets).
  - The White tab is the colour temperature alone, over the union of the tunable lights' ranges; each light stops at its own warm and cool LEDs.
  - There is no level slider: the brightness pill dims them.
  - W lights never get a colour or temperature. With any present, the tab says "W lights keep their white"; they get power, brightness, effects and the timer.
  - The screen takes the warm tone of a white light: a CCT light at the group's temperature (the lights' mean when they differ), or a W light when there are only W lights. The Colour lights screen follows its colour.
- **Effects:** every mode some light of the group has. A mode only some lights have shows "n/m" and goes only to those; the app then says "Applied to n of m lights".
- **Group presets:** 15 slots per group, kept on this phone. They never use the lights' own preset slots, so each light's presets stay untouched.
  - An empty slot saves each connected, following light's look (colour, effect with speed and frequency, on or off; in Colour lights also its colour sources and police beacons) and the group brightness. If some lights were missing, it says "Saved n of m lights".
  - A filled slot applies it. For each light in the preset: colour, then effect, then the group brightness at that light's level, then power. Lights not in it are untouched, and lights on their own settings or left out are skipped. A light that connects later gets its look when it does.
  - The last applied slot is marked until the next group command (not the sleep timer, which is never part of a preset). Long-press to Load / Rename / Overwrite / Clear.
  - A forgotten light is dropped from every preset; a preset left with no lights becomes empty.
- **Level in group (trim):** every row shows its level in a small pill (sun, "100 %", chevron). Tap the pill or the row to set it with a slider, from 5 to 100 %; tap again to close. The light follows the slider while you drag (that light only); the level is saved when you let go.
  - It gets the group brightness times its level, never 0 while the group is on; the group at 0 turns every light off.
  - A trimmed light doesn't make the brightness read "Mixed".
  - Changing a level never detaches a light.
- **Own settings:**
  - A light that has followed a group command and is then changed on its own screen or its Home tile (colour, brightness, effect, colour source, police beacon, power, preset) keeps its own settings. Group commands skip it until it rejoins.
  - The timer, levels, renaming, Identify and sound don't detach a light; neither do changes from another phone or a power cycle.
  - In the list, the switch is on while a light follows. Off, the row says **Own settings** or **Excluded**; turning it on rejoins the light. **Rejoin all** brings every light back.
  - **Rejoining matches the group at once**, also in a later session: each group remembers its look (colour or temperature, effect with speeds and frequencies, colour sources and police beacons, the applied preset, brightness and power). A rejoined light gets that look, then the group brightness at its level, then power: straight away if it is connected, otherwise when it connects while the group is open. It follows the group again once the look has reached it.
  - With no light following, the controls give way to a message and **Rejoin all** / **Include lights**. With none connected, the controls are off and the status says "No lights connected".
- **Broadcast, not sync:** the same commands go to every light, but each light runs its own effect clock. Two lights running Rainbow are not in step.
- **Connection limits:** while a group is open, the app connects its lights, favourites first and then in Home's order, up to what this phone allows at once (8 on iOS, 5 on Android). Any others are reported as left out. Leaving the screen releases them after the normal idle grace (60 s).
- **Catch-up:** a light that connects while the screen is open gets what the group was sent while the screen was open, as far as it applies to it: its look (its own from an applied preset), brightness (at its level), power, then the timer's remaining time (skipped if under 5 s). Nothing is replayed after you leave.
- **Lights in this group:** each light's type, name, connection and state in the group, its level, **Flash it** (Identify) and its switch. Excluded, own settings, levels and presets are remembered.

## 4. Light settings
- **Name**, **Favourite**, and **Type** (read from the firmware).
- **What this light can do** shows:
  - its channels in wire order;
  - effects "12 of 13", and why any are missing;
  - its presets, timer and sound;
  - the firmware model, version and raw capabilities (long-press to copy).
- **Identify** (Home, the add flow, **Flash it** in groups): a light whose firmware has IDENTIFY (3.6.1+) is sent just that; it flashes twice, chirps once and restores itself, also while asleep. Older firmware dips twice from its level to the lowest one and back (150 ms each) and gets its exact level again: never off, no power change, no sound, and nothing while it sleeps.
- **Channel test** lights each LED on its own for 1.2 s, then restores the look. If the link drops during the test, the look is restored when the light returns within 60 s.
- **Sound**, **Factory reset** (the confirmation shows the type's factory look; it also clears the preset names) and **Forget**.

## 4a. Developer tools
- **Settings → Advanced → Developer tools** (off by default, remembered). When it is on, Settings and each light's settings have a **Developer** row. When it is off, nothing of it shows.
- **Developer** lists every saved light with its type, firmware version and connection state. A light opens its developer page, which keeps it connected:
  - **Fixture type:** the current type. Firmware without CAPS `TYPES=` gets "Changing the type needs firmware 3.7.0 or later".
  - **Find the right type** (CAPS `PROBE=1`): the app lights each output with PROBE (red, green, blue, white/cool, warm) and asks "Is it lighting up?" (Yes / No / Retry). It then suggests the type that drives exactly those outputs; any other combination gets a clear message. The suggestion is preselected, and all five types stay selectable.
  - **Change type:** a confirmation (the light restarts, its presets are cleared, it moves to the matching group), then SET_TYPE. The page waits while the light restarts and is re-identified, then shows the result.
  - **Firmware:** the installed version, the version bundled with the app, and **Reinstall firmware** (the update flow of §4b with the reinstall flag; never a downgrade).
  - **Install rollback test image** (debug builds only): choose **Fails its check** or **Freezes**. The light installs that test image (firmware 3.8.1 `--rollback-test` builds, version 3.8.9999), restarts, fails, and must return to its previous firmware on its own; the result shows DIAG's `rb=1` and that the slot is the one it ran before. `tool/bundle_firmware.sh` bundles the two images as generated Dart data reached only behind `kDebugMode`, so profile and release builds contain neither the images nor the option (`test/features/developer/rollback_test_release_test.dart`; `tool/check.sh --builds` also scans the release binary).
  - **Diagnostics:** DIAG in plain words (running time, last restart reason, firmware slot, rollback since the last install, whether new firmware has confirmed itself (3.8.2 `pv`), then the rendering, connection and memory counters, including the last update's final check time `endms`), with Refresh and Copy (readable text plus the raw reply).

## 4b. Wireless firmware updates
- **What's bundled:** `tool/bundle_firmware.sh` builds the type-neutral update image (`firmware/tools/build_update_image.sh`) and puts it in `assets/firmware/` with `manifest.json` (version, size, SHA-256, product, image kind, file). The app reads the manifest at start; the image is loaded and checked against it when an update begins. `test/cross_repo/firmware_bundle_test.dart` checks the manifest against the file and the firmware's `kFirmwareVersion`.
- **When it's offered:** a connected light whose firmware has the update service (3.8.0+), a spare slot (3.8.2+ CAPS `OTA=`; `OTA=0` means it cannot update wirelessly) and is older than the bundled version gets an update badge on its Home tile, Home shows "1 light has an update", and its settings have **Update firmware**. Older firmware without the service gets a note that it needs one USB install. A downgrade is never offered or sent.
- **The update screen** says what will happen and "Keep the app open and stay near the light", then shows the progress with percentage and time left. **Cancel** works until the whole image has arrived (ABORT; the light keeps its firmware); after that the light installs it on its own. The screen stays awake for the whole update.
- **Engine** (`sessions/firmware_update.dart`, protocol §10): BEGIN (retried; a resumed transfer continues from the offset the light reports), DATA up to MTU − 3 bytes per write with one 8 KB window in flight, STATUS when an ACK is missing, END, ABORT. A dropped link mid-transfer is resumed once the light is back. Every ERROR code has its own message.
- **While a light updates** (from the first byte until the new firmware is confirmed): its command and colour lanes are paused, its own controls and groups skip it, Home says "Updating…", and only one light updates at a time.
- **After END_OK** the light restarts; the app waits for it to reconnect (same device), checks the version and, once the new firmware's 15 s self-check window has passed, DIAG's `rb` and `slot`. A rollback is reported as "The update didn't take; your light is back on its previous firmware."
- **Demo mode:** the demo RGB light runs 3.7.0, so the whole flow can be tried: the simulated light receives the bundled image in about 5 s, restarts and confirms it like the firmware.

## 5. How it stays in sync
- **Handshake:** INFO names the layout, CAPS confirms it (`LAYOUT`, `MODES`), and then STATUS, MODE_SETTINGS and PRESET_LIST are read.
  - Lights that can't be controlled are shown as such, never retried in a loop: the original firmware ("Firmware update needed"), an unknown layout ("Needs a newer app version") or malformed replies.
- **What goes on the wire:**
  - Colour and brightness go as binary frames (n + 4 bytes, salted per layout), paced, with the newest value winning.
  - Every other setting is a typed text command with one reply-bearing command in flight at a time.
  - Changes are applied optimistically and confirmed or rolled back.
- **Nothing is sent for a mode the light doesn't have:** it fails locally with `MODE_UNSUPPORTED`.

## 6. Code layout (`app/lib`)

| Folder | Contents |
|---|---|
| `core/model` | `ChannelLayout`, `ChannelColor`, `LightCapabilities`, `Fixture` |
| `core/protocol/eb` | Commands, replies, frames, scenes, the fixture catalogue and the mode catalogue |
| `core/color` | Colour engine (HSV / Kelvin / raw per layout), LED white points, display colour |
| `core/store` | Atomic JSON store and the one-time import of the old app's data |
| `drivers/electrobright` | Session: handshake, command lane, stream lane, reconciliation |
| `sessions` | Connection manager, discovery, per-light session, registry, colour and white groups with their presets, identify / channel test |
| `sim` | Firmware twin and simulated Bluetooth (demo lights and tests) |
| `design` | Tokens, theme, glass, controls, haptics, gallery |
| `features` | Onboarding, Home, add light, control screen, groups, light settings, developer tools, firmware update, diagnostics |

## 7. Run and test
```bash
cd app
flutter run                                  # simulator (demo lights) or a connected phone
flutter run --release -d <iphone-id>         # install on an iPhone (Developer Mode on)
tool/check.sh                                # format, analyze, firmware host tests, all app tests (conformance: make -C ../firmware/test conformance)
flutter test integration_test -d <simulator> # end-to-end flow with every demo light type
```

The app's tests include:
- the real firmware core in the loop (`fwsim`) for every fixture: sessions, fuzzing and identify / channel test;
- cross-repo checks that the app's catalogues match the firmware sources;
- widget tests and screenshot baselines per light type.
