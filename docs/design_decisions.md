# Design decisions

One entry per decision: what, why, what was rejected, and where it happened. How the parts fit is in [architecture.md](architecture.md); user-visible history is in [CHANGELOG.md](../CHANGELOG.md).

## Lights are identified by Bluetooth device id
- **Decision:** a saved light is keyed by its Bluetooth device id, never by its name or type. Default names are numbered per type to be unique ("RGBW light 2"; `add_light_screen.dart`, tested in `test/features/home_flow_test.dart`).
- **Why:** every light of a type advertises the same BLE name, so identical lights must coexist.
- **Rejected:** matching by advertised name.
- **Where:** unique default names in 98a5c8a.

## Bluetooth only; the app is the only writer
- **Decision:** no server or cloud. A light accepts one phone at a time, and while connected the app is its only writer: a differing STATUS at resync is treated as a lost write and re-sent.
- **Why:** the old app's instability came from races between local state and the light's STATUS replies; no server keeps setup trivial and private.
- **Rejected:** Wi-Fi, a cloud service, DMX.
- **Where:** app v2 sync engine, 2f360f4.

## PWM at 25 kHz, 11 bits + 4-bit dithering
- **Decision:** `kPwmFreqHz = 25000`, `kPwmBits = 11`, `kPwmDitherBits = 4` (15 effective bits; `config/Config.h`).
- **Why:** at 4.9 kHz the buck converters whined under the pulsed load. 80 MHz / 2^11 is the most resolution LEDC allows at ~25 kHz; the hardware fractional duty restores the lost bits.
- **Rejected:** 14-bit at 4.9 kHz (audible).
- **Where:** firmware 3.6.1, 6c0fc36.

## Full brightness holds the pin high
- **Decision:** a duty above period − 1 whole counts stops the channel with its idle level high; no PWM on-time ever reaches a full period (`platform/PwmPlan.h`). The lowest level is one whole count (`kPwmMinDuty = 16`), never a dithered fraction, so it doesn't flicker.
- **Why:** in 3.6.1 a dithered full-period on-time made LEDC stay low for that period, so at exactly 100 % the light went dim (about 1/16) and effect peaks glitched.
- **Rejected:** clamping the duty just below full inside PWM.
- **Where:** firmware 3.6.2, 62f5ed5.

## Continuous colour-to-white mapping on CCT
- **Decision:** on CCT, coloured effect light becomes a white temperature continuously (`render/ChannelMap.h`, `colourToWhites`).
- **Why:** the Rainbow "Temperature sweep" is smooth at steady brightness.
- **Where:** mapping introduced with the CCT fixture (e13342d); made smooth in 3.6.1 (6c0fc36, "smooth CCT sweep"). The exact earlier behaviour is not re-verified here.

## 15 preset slots
- **Decision:** 15 slots per light, shown as 3×5; old presets wiped once.
- **Why:** more room, one clean format. The wipe is marked only after every old slot is gone, so an interrupted boot retries (`state/StateStore.cpp`).
- **Where:** firmware 3.6.0, 1af4e3c; app 599d42d.

## Brightness 0 turns the light off
- **Decision:** releasing brightness at 0 sends the 0 frame, then exactly one SLEEP; the level to wake to is stored after the sleep fade (`wakeBrightnessDelay` = `sleepFadeMs` 400 ms + 150 ms; `eb_session.dart`).
- **Why:** Apple Home-style behaviour, and the light must wake to the previous level, not to 0.
- **Rejected:** a separate off switch only; sending SLEEP on every 0 during a drag.
- **Where:** 98c2e09.

## The colour display follows the finger; pills use brand glass
- **Decision:** while dragging, the display shows the pick exactly; otherwise it glides. Pill sliders are frosted periwinkle glass (`PillFill`/`PillGlass` in tokens), never the light's colour.
- **Why:** gliding lagged the finger; colour-following pills kept glitching.
- **Where:** 135d2ba (follow the finger), 55835cd (brand pills).

## Automatic groups by type
- **Decision:** Colour lights (RGB, RGBW, RGBCCT) and White lights (CCT, W); one group active at a time; per-light trim never detaches; a light gets "own settings" only if it was following and was changed on its own screen; rejoining applies the stored group look; group presets live on the phone.
- **Why:** mixing types made the controls confusing.
- **Rejected:** one All Lights group (1c4b12d … b377c70), replaced by per-kind groups.
- **Where:** 63227ab, d263f8a, e500110, 75e7b52. Behaviour: [app.md §3](app.md#3-groups).

## Identify is a firmware command
- **Decision:** IDENTIFY flashes twice and chirps once (`SoundId::Identify`), then restores. The app's fallback for older firmware dips to the lowest level and back (150 ms), never to 0.
- **Why:** a crisp, recognisable signal that can't leave a light off.
- **Where:** firmware 3.6.1 (6c0fc36); app a8b1c7b.

## Performance: nothing draws when nothing changes
- **Decision:** static glyphs don't tick; animated glyphs draw only when they step; the fast scan runs only on the add screen and Home uses a low-power filtered scan; iOS is capped at 60 Hz; Android asks for high refresh only while something moves (`refresh_governor.dart`).
- **Why:** a device baseline showed heavy GPU load and heat from 120 Hz tickers.
- **Rejected:** cheaper glass, a simulator idle tick.
- **Where:** perf steps 2926411 … ca257ba; 5e6f5d4 (iOS 60 Hz); 62e073a (high refresh only while moving); fast scan off Home in 0de3258.

## Light theme: coloured under-light
- **Decision:** light mode uses coloured under-light, specular rims and a contrast policy instead of dark glows.
- **Where:** f7b3f3e.

## Home shows only your lights
- **Decision:** nearby lights sit behind a count badge on Add light; "Not mine" and unsupported lights are on the add screen.
- **Where:** 0de3258.

## One universal firmware
- **Decision:** one image; the type is stored in NVS (`ebsys`/`fx`); SET_TYPE, PROBE and a setup-needed mode; factory reset keeps the type (`test_universal.cpp: factory_reset_keeps_the_fixture_type`).
- **Why:** one image to build, bundle and update; a light's type can be fixed from the app.
- **Rejected:** one firmware per fixture (the 3.5.0 family).
- **Where:** firmware 3.7.0, 9ed0089.

## Wireless updates
- **Decision:** two slots; windowed, acknowledged transfer with resume; identity block; no downgrades; 15 s self-check with bootloader rollback. The task watchdog is reconfigured, not initialised, because the Arduino core starts it first (`core/WatchdogPlan.h`). Firmware is bundled in the app, so app-store releases are the distribution channel.
- **Why:** no USB after the first install, and no server.
- **Where:** firmware 3.8.0 (9349bd9), 3.8.1 (cde688f); app 473f963. Security limits: [security.md](security.md).

## Developer tools hidden
- **Decision:** behind Settings → Advanced, invisible when off.
- **Where:** a25308f.

## Connection limits
- **Decision:** at most 5 links on Android, 8 on iOS, favourites first; offline changes wait 60 s and aren't kept across restarts (`connection_manager.dart`, `fixture_session.dart`).
- **Why:** platform BLE limits; stale changes shouldn't surprise later.
- **Where:** group budget in 63227ab. The origin commit of the 60 s window was not traced.
