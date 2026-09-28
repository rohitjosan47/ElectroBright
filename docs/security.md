# Security

The honest state as of app 2.0.0 / firmware 3.8.2. **ElectroBright is not yet ready for a public release from a security point of view:** a light trusts any phone in Bluetooth range.

## What is not protected

- **No pairing, bonding or ownership.** A light accepts a connection from any Bluetooth device in range while it is advertising, and executes every command it receives. "Your lights" exist only in your app's list; the light itself has no owner.
- **Every command is open**, including the destructive ones:
  - colour, effects, presets, sound, sleep timer, factory reset;
  - `SET_TYPE` (changes the fixture type, restarts the light, clears its presets);
  - wireless firmware updates (the update GATT service, [protocol.md](protocol.md) §10).
- **Firmware images are not signed.** The 64-byte identity block (`firmware/core/ElectroBrightCore/src/ota/ImageIdentity.h`: magic `EBIMGID1`, product, kind, version) only proves an image *says* it is an ElectroBright image. Anyone can build one with the public sources, or copy the block into their own image, and a light will install it.
- **No link encryption at the application level.** Traffic can be observed with a Bluetooth sniffer.
- **The app's own data** (light list, names, presets, group looks) is stored unencrypted in the app's private storage on the phone.

## What is protected

These guard against accidents and broken transfers, not against an attacker.

| Protection | How |
|---|---|
| Corrupted transfer | The whole image's SHA-256 must match what BEGIN announced (`HashMismatch`), and ESP-IDF must accept it as a valid app image. |
| Wrong file | The image must carry an ElectroBright universal identity of the announced version (`NotElectroBright`). |
| No downgrades | An older version is refused (`Downgrade`); the same version only with the reinstall flag (`SameVersion`). An attacker who builds a *higher* version number is not stopped. |
| Bricking | Two update slots: the running firmware is untouched while the new one is written. After restart the new firmware must pass its own self-check within 15 s, or the bootloader returns to the previous slot (rollback). |
| Update while busy | One transfer at a time; a light that hasn't confirmed new firmware refuses another (`Busy`). |
| One writer (in practice) | The light advertises only while nobody is connected (`advertiseOnDisconnect` in `firmware/core/ElectroBrightCore/src/platform/BleNus.cpp`), so a second phone normally can't find it while you are connected. This relies on NimBLE's default behaviour; a hard one-connection limit is not set explicitly and is unverified. |

Error codes are defined in `firmware/core/ElectroBrightCore/src/ota/OtaProtocol.h`.

## Planned before a public release

Not implemented; recorded here so it isn't forgotten.

1. **Firmware signing.** Sign release images with a private key kept off the repository; the light verifies the signature before switching slots (ESP-IDF Secure Boot v2 or an application-level Ed25519 check in `OtaReceiver`). The identity block stays as the product/version check.
2. **Ownership / pairing.** The first phone to set up a light becomes its owner (e.g. a pairing secret shown or confirmed with a button press or power-cycle window); other phones need that secret or an owner-issued invitation. At minimum `SET_TYPE`, factory reset and updates must require it.
3. **Bluetooth bonding with encryption** once ownership exists, so traffic can't be read or replayed.
4. **A way to recover** a light whose owner lost their phone (a physical reset procedure).

Report security issues to the maintainer directly rather than in a public issue.
