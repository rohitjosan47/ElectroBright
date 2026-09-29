# ElectroBright User Guide

This guide is for people who use ElectroBright lights. If something doesn't work, see [Troubleshooting](troubleshooting.md).

## What ElectroBright is

ElectroBright is a set of LED lights that you control from your phone over Bluetooth. There is no account, no hub and no internet connection. Your phone talks to each light directly when it's nearby.

There are five kinds of light:

| Kind | What it can show |
|---|---|
| RGB | Any colour |
| RGBW | Any colour, plus a separate white LED |
| RGB+CCT | Any colour, plus warm and cool white LEDs |
| Tunable white (CCT) | White from warm to cool |
| Single white (W) | One white, brighter or dimmer |

The app shows only the controls your light can use.

## First launch

- **Try demo lights** gives you one pretend light of every kind. Use them to explore the app without any hardware. A "Demo" badge marks them. You can switch to demo lights later from Settings on Home.
- **Your lights:** the app asks for Bluetooth permission. Allow it, or the app can't find or control your lights. On Android, the app may also ask for location permission. Older Android versions need it to scan for Bluetooth devices. The app doesn't use your location.

With no lights saved, Home shows **Add your first light**.

## Adding a light

1. Switch the light on.
2. On Home, look at the **Add light** button. A number on it tells you how many new lights are nearby.
3. Tap **Add light** and pick your light from the list.
4. The app connects and tells you what kind of light it found. Tap **Flash it** to make the light blink twice (and chirp, if its sound is on), so you know which one it is.
5. Give it a name and tap **Save**. Nothing is saved until you do. **Cancel** leaves the light alone.

A light that belongs to a neighbour? Tap **Not mine**. It disappears from the list and the badge. **Show hidden lights**, at the bottom of the add screen, brings them back.

Lights listed under **Unsupported lights** run very old firmware. They need a one-time update over USB before this app can control them.

## Controlling a light

Tap a light on Home to open it. You can also switch it on or off with the power button on its tile. Long-press a tile for Rename, Identify, Light settings or Forget.

- **Brightness:** drag the big slider. You feel a tick every 10 %. Drag it to 0 to switch the light off. Touch it again and the light comes back at the brightness you had before.
- **Colour:** on colour lights, pick a colour on the wheel. RGBW lights also have a **White LED** slider. On RGB+CCT lights, switch between **Colour** and **White**.
- **Whites:** on tunable-white lights, choose the colour temperature from warm to cool. The brightness slider dims it.
- **Effects:** choose one of up to 13 effects, such as Fire, Thunderstorm or Rainbow. Each effect shows only its own sliders, for example speed or how often something happens. Some effects let you choose between your colour and an automatic palette.
- **Presets:** each light has 15 slots. Tap an empty slot to save the current look and name it, or tap a filled slot to load it. Long-press a slot to rename, overwrite or clear it.
- **Timer:** set a sleep timer from 30 seconds to 24 hours. The light switches off when it runs out. A countdown shows while it runs.
- **Sound:** switch the light's beeps on or off.

## Groups

Once you have two or more lights of a similar kind, the app groups them for you. A **Groups** card appears at the top of Home.

- **Colour lights:** RGB, RGBW and RGB+CCT lights. They share brightness, colour, effects, presets and the sleep timer. A colour you pick is sent with the white LEDs off, so all the lights match.
- **White lights:** tunable-white and single-white lights. They share brightness, colour temperature, effects, presets and the timer. Single-white lights keep their white and ignore the temperature.

Only one group is open at a time. When the lights differ, the controls say **Mixed** until you set them all.

- **Level in group:** each light in the list has a small level pill. Use it to make one light a bit dimmer than the others, from 5 % to 100 %. It never takes the light out of the group.
- **Own settings:** if you change a light on its own screen after the group has controlled it, it keeps its own settings and the group skips it. Turn its switch back on in the group's light list to rejoin. It then takes on the group's look straight away. **Rejoin all** brings every light back.
- **Group presets:** 15 slots per group, saved on your phone. They don't touch each light's own presets.

## Updates

When a light can get newer firmware, Home shows a banner such as "1 light has an update". The light's settings then have **Update firmware**.

- Keep the app open and stay near the light. The screen stays on during the update.
- You can cancel until the whole update has arrived. After that, the light finishes on its own and restarts.
- If the connection drops, the update continues where it stopped once the light is back.
- If anything goes wrong, the light keeps its current firmware, or goes back to it on its own. Your settings and presets stay either way.

Lights that are too old for wireless updates need one update over USB first. The app tells you when that's the case.

## Light settings

Open them with **Light settings** in the toolbar on a light's screen, or by long-pressing its tile on Home.

- **Name**, **Favourite** and the light's type.
- **What this light can do:** its LEDs, effects, presets and firmware version.
- **Identify:** the light flashes twice and, if its sound is on, chirps.
- **Channel test:** lights each LED on its own for a moment, so you can check the wiring.
- **Sound**, **Factory reset** and **Forget**.

## Tips

- Mark the lights you use most as **Favourite**. The app connects to them first.
- Name lights by room ("Kitchen shelf") so they're easy to find.
- Use a light's own presets for looks you use on that light. Use group presets for looks across a room.

## FAQ

**Why does a light show "Phone limit" in a group?**
A phone can only stay connected to a few Bluetooth lights at once. The app connects your favourites first. The rest show "Phone limit" and don't follow the group until a connection frees up. See [Limitations](limitations_and_roadmap.md).

**Why aren't effects on several lights in step?**
Each light runs its own effect clock. Starting Rainbow on two lights at once sends the same command to both, but they drift apart over time.

**Why does my white light have no colour wheel?**
It only has white LEDs, so it can't show colours. A tunable-white light lets you choose warm or cool white instead. A single-white light only has brightness.

**What does "Setup needed" mean?**
The light doesn't know yet what kind of LEDs it drives. Tap it, and the app helps you find the right type by lighting each output and asking you what you see.

For anything else, see [Troubleshooting](troubleshooting.md).
