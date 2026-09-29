# Testing

What each automated suite proves, how to run it, and the checklists for real hardware. For the firmware build itself see [firmware.md](firmware.md); for the release gate see [release.md](release.md).

## 1. The gate: `app/tool/check.sh`

```bash
app/tool/check.sh            # format, analyze, firmware host tests, all app tests
app/tool/check.sh --builds   # ...plus iOS simulator build, signed Android release APK,
                             #    and a scan that the release APK has no rollback test images
```

In order: `dart format` on hand-written sources (generated `*.g.dart` and l10n excluded), `flutter analyze`, `make -C firmware/test` (host tests and fwsim), `flutter test`. With `--builds`: `flutter build ios --simulator --debug`, `flutter build apk --release`, then `app/tool/check_release_excludes_tests.sh` on the APK.

It does **not** run the conformance suite or the integration test; run those separately (below).

## 2. Firmware suites (`firmware/test`)

| Command | What it proves |
|---|---|
| `make -C firmware/test` | Builds the portable core with ASan/UBSan and `-Werror`, runs every host test (`test_*.cpp`: PWM plan, render, layouts, protocol, controller, state, OTA, universal firmware, one file per fixture type, fwsim) and the RGBW golden (`golden/rgbw.golden`, pinned to the v3.4.0 baseline), checks portable code includes no Arduino/ESP-IDF headers, and builds `build/fwsim/fwsim`. |
| `make -C firmware/test run T=club` | Only tests whose name contains `club`. |
| `make -C firmware/test conformance` | Runs `firmware/tools/fw_conformance.py` against fwsim for rgbw, rgb, rgbcct, cct and w (`--stress 3 --factory-reset`): every reply checked against [protocol.md](protocol.md). |
| `make -C firmware/test golden-record` | Re-records the RGBW golden. Only for an intended RGBW behaviour change. |

The same conformance suite runs against a real light over Bluetooth (`pip install bleak`); the options are listed at the top of `fw_conformance.py` and in [firmware/README.md](../firmware/README.md). `--factory-reset` wipes presets.

## 3. App suites (`app/test`, `app/integration_test`)

Run all with `cd app && flutter test`; one folder with `flutter test test/<folder>`.

| Folder | What it proves |
|---|---|
| `core`, `store`, `sim` | Protocol codecs, colour engine, JSON store, the firmware twin's identify and type behaviour. |
| `sessions` | Connection manager (limits, eviction, backoff), registry, type changes, groups, the update engine. |
| `features`, `design` | Widget tests of every screen and control, in demo mode. |
| `goldens` | Screenshot baselines: control screen per type (dark/light, 1x; RGBCCT also 2x text), groups, developer page, add screen, gallery. Update with `flutter test --update-goldens test/goldens` only for an intended visual change. |
| `cross_repo` | The app's copies of firmware facts match the firmware sources: mode registry, fixture catalogue, config, OTA protocol constants, and the bundled firmware manifest vs the file and `kFirmwareVersion`. |
| `fw_in_the_loop` | The real firmware core (fwsim, tag `fwsim`) behind the app's sessions for every fixture: session tests, fuzzing, a differential test against the Dart twin, OTA differential (fwsim vs `lib/sim/ota_twin.dart`), identify/channel test rituals. Needs `make -C firmware/test fwsim` first (check.sh does it). |
| `perf` | `idle_activity_test.dart`: frames, tickers, scans, rebuilds and store writes while nothing changes (numbers in `app/build/perf/idle_activity.txt`). `frame_rate_independence_test.dart`: animations match at 60 and 120 Hz. |
| `integration_test` | `app_flow_test.dart`: onboarding, adding one demo light of every type, each type's controls against its twin, groups, developer tools and a wireless update. Run with `flutter test integration_test -d <simulator id>`. |

There is no separate scale suite.

**Reproducing a fw-in-the-loop failure:** a failure prints fixture, seed and step and saves the fwsim transcript to `app/build/test_failures/`. Re-run one case with `DIFF_CASE=<fixture>:<seed>` (differential) or `FUZZ_CASE=<fixture>:<schedule|fault>:<seed>` (fuzz). Don't run two `flutter test` processes in one project at once: they race on `build/native_assets`.

## 4. Hardware checklists

No suite touches real hardware. Run these after a firmware change, with a meter or your eyes and ears. Record the firmware and app versions.

### Output
- [ ] **Full brightness:** white at 100 % is the brightest; no dimming or flicker at exactly 100 %.
- [ ] **99 ↔ 100 %:** drag between them; the step is small and there is never a dark or glitching frame. Effects with peaks at full (Strobe, Thunderstorm) don't glitch.
- [ ] **Dimmest levels:** 1 % and the lowest slider positions are steady, no flicker.
- [ ] **Noise:** no whine from the buck converter or strip at any level (PWM is 25 kHz; see [wiring_guide.md](wiring_guide.md)).
- [ ] **MOSFET warmth:** after 10 min at 50 % and at 100 %, MOSFETs are no more than warm to the touch.
- [ ] **CCT sweep:** Temperature sweep (Rainbow on CCT) glides warm↔cool at steady brightness, no steps.
- [ ] **Identify:** two crisp flashes and one chirp (sound on), then the previous look; also while asleep.

### Groups (two or more real lights)
- [ ] Brightness, effect and timer reach every following light.
- [ ] Trim a light; the group brightness scales it and it never goes off while the group is on.
- [ ] Change one light on its own screen: it shows **Own settings**; rejoin applies the group look.
- [ ] **Catch-up:** with the group open, power-cycle one light; when it reconnects it gets the look, brightness, power and remaining timer.

### Wireless updates (bundled image newer than the light)
- [ ] **Normal:** update completes, the light comes back on the new version, DIAG `rb=0`, `slot` changed.
- [ ] **Interrupted at the wall:** cut the light's power mid-transfer; after power returns, **Update** resumes from where it stopped and completes.
- [ ] **Out of range:** walk away mid-transfer; the app reports a lost link; come back and it resumes.
- [ ] **Rollback, both images** (debug build, Developer → Install rollback test image): **Fails its check** and **Freezes** each end with the light back on its previous version, DIAG `rb=1` and the previous slot.
