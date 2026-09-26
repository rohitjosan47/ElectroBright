# ElectroBright App

The Flutter app in `app/` (iOS and Android) controls every ElectroBright fixture over Bluetooth Low Energy. It reads what each light's firmware can do and builds its controls from that. The wire contract is in [protocol.md](protocol.md).

## 1. Lights and connection
- **Home** lists your saved lights. Each tile has:
  - a colour orb, the name, the **type badge** (e.g. "Tunable white" with one dot per LED) and a state line such as "On · 80 % · Fire";
  - a presence line (Connected, Connecting…, or Unavailable: off, out of range, or connected to another phone) and a power button.
  - Long-press a tile for Rename, Identify, Light settings or Forget.
- **Nearby — not added** shows lights that are advertising, with their type read from the Bluetooth name. A light on the original firmware shows "Update needed".
- **Add a light** has these steps:
  1. The app connects and reads the light's identity ("Found a Tunable white light · firmware 3.6.0").
  2. **Flash it** blinks the light so you can find it.
  3. You name it.
  4. Save. Nothing is saved until Save, and Cancel always disconnects.
- **Connection:**
  - Lights you open are connected, plus up to three favourite or recent lights while Home is open.
  - A dropped link reconnects on its own.
  - Changes made while reconnecting are sent when the light is back if they are less than 10 s old.
  - In the background every light is released after 20 s.
- **Demo lights** (onboarding, or Settings on Home): one simulated light of every type plus one on the original firmware. They run a copy of the firmware logic.
- **Reflashed as another type:** a light reflashed as a different fixture type is detected on the next connect ("Kitchen is now a CCT light"). Its saved presets and last state are reset.
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
- Police beacons are picked with the light's own colour controls.

**Presets.**
- The 15 slots on the light, with a preview in its colours; W shows the output %.
- Tap to load, tap an empty slot to save and name it, long-press to Load / Rename / Overwrite / Clear.
- "Current look: …" or "Modified from …" is shown above the slots.

**Timer.** A dial from 30 s to 24 h, with a live countdown under the toolbar.

**Sound.** Turns the light's buzzer on or off.

## 3. All Lights
With two or more saved lights, Home shows an **All Lights** card at the top: the only way in. It opens one control surface for the saved lights, whatever their types, including several lights of the same type and firmware.

- **What it does:** power, brightness, colour, effects (with their speed and frequency) and the sleep timer, sent at the same moment to every light that follows the group.
- **Adaptive controls:** the colour controls are those of a single light with the group's mix of LEDs, built the same way as a light's own screen:
  - colour and tunable white give Colour | White;
  - colour with an RGBW light gives the wheel and a White LED slider;
  - colour only gives the wheel;
  - tunable whites only give a **White** tab;
  - single whites only give no colour tab: Effects are shown directly.
- **Where each control goes:**
  - A colour goes only to lights with colour LEDs.
  - A temperature goes to tunable whites (each stops at its own warm and cool LEDs) and colour lights (which match it).
  - Single-white lights keep their white and get only power, brightness, effects and the timer.
  - A caption says when a control reaches part of the group ("Colour · 3 of 5 lights", "White LED · 1 of 5", "Temperature · 4 of 5 lights", "1 white light keeps its white", "1 light at its limit").
  - With tunable and single-white lights together, **Match W lights · 4000 K** sets the tunable ones to the single whites' temperature.
- **Effects:** every mode at least one connected light has. A mode only some lights have shows "3/5" and goes only to those; the app then says "Applied to 3 of 5 lights". When the lights differ, the controls say so ("Mixed", "Timers differ") until you set them all.
- **Level in group (trim):** tap a light in the list to set its level in the group, from 5 to 100 %. It gets the group brightness times its level, never 0 while the group is on; the group at 0 turns every light off. A trimmed light doesn't make the brightness read "Mixed", and a collapsed row shows its level ("Level 50 %").
- **Own settings:**
  - A light that has followed a group command and is then changed on its own screen (colour, brightness, effect, power, preset) keeps its own settings. Group commands skip it until it rejoins.
  - The timer, renaming, Identify and sound don't detach a light; neither do changes from another phone or a power cycle.
  - In the list, the switch is on while a light follows. Off, the row says **Own settings** or **Excluded**; turning it on rejoins the light and catches it up. **Rejoin all** brings every light back.
  - With no light following, the controls give way to a message and **Rejoin all** / **Include lights**. With none connected, the controls are off and the status says "No lights connected".
- **Broadcast, not sync:** the same commands go to every light, but each light runs its own effect clock. Two lights running Rainbow are not in step.
- **Connection limits:** while All Lights is open, the app connects the lights in the group, favourites first and then in Home's order, up to what this phone allows at once (8 on iOS, 5 on Android). Any others are reported as left out. Leaving the screen releases them after the normal idle grace (60 s).
- **Catch-up:** a light that connects while the screen is open, or rejoins, gets what the group was sent while the screen was open, as far as it applies to it. The order is look, brightness (at its level), power, then the timer's remaining time (skipped if under 5 s). Nothing is replayed after you leave.
- **Lights in this group:** each light's type, name, connection and state in the group, its level, **Flash it**, a way to its own screen, and its switch. Excluded, own settings and levels are remembered.
- **Why no presets:** presets live on each light (15 slots per light, in its own colours and channels), so there is no single preset every light can load.

## 4. Light settings
- **Name**, **Favourite**, and **Type** (read from the firmware).
- **What this light can do** shows:
  - its channels in wire order;
  - effects "12 of 13", and why any are missing;
  - its presets, timer and sound;
  - the firmware model, version and raw capabilities (long-press to copy).
- **Identify** blinks the light three times.
- **Channel test** lights each LED on its own for 1.2 s, then restores the look. If the link drops during the test, the look is restored when the light returns within 60 s.
- **Sound**, **Factory reset** (the confirmation shows the type's factory look; it also clears the preset names) and **Forget**.

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
| `sessions` | Connection manager, discovery, per-light session, registry, All Lights group, identify / channel test |
| `sim` | Firmware twin and simulated Bluetooth (demo lights and tests) |
| `design` | Tokens, theme, glass, controls, haptics, gallery |
| `features` | Onboarding, Home, add light, control screen, All Lights, light settings, firmware update, diagnostics |

## 7. Run and test
```bash
cd app
flutter run                                  # simulator (demo lights) or a connected phone
flutter run --release -d <iphone-id>         # install on an iPhone (Developer Mode on)
tool/check.sh                                # format, analyze, firmware tests + conformance, all app tests
flutter test integration_test -d <simulator> # end-to-end flow with every demo light type
```

The app's tests include:
- the real firmware core in the loop (`fwsim`) for every fixture: sessions, fuzzing and identify / channel test;
- cross-repo checks that the app's catalogues match the firmware sources;
- widget tests and screenshot baselines per light type.
