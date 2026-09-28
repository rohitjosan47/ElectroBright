# ElectroBright app

Flutter app (iOS, Android) for every ElectroBright fixture: RGBW, RGB, RGBCCT, CCT and W. The controls follow what each light's firmware reports it can do.

```bash
flutter run                              # simulator: choose "Try demo lights"
flutter run --release -d <iphone-id>     # install on an iPhone
tool/check.sh                            # format, analyze, firmware + app tests
tool/bundle_firmware.sh                  # rebuild the bundled update image (+ debug-only rollback test images)
```

The full guide is [docs/app.md](../docs/app.md), and the wire contract is [docs/protocol.md](../docs/protocol.md); every document is listed in [docs/README.md](../docs/README.md).
