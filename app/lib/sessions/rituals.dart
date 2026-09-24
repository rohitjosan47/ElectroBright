import 'dart:async';

import '../core/model/channel_color.dart';
import '../core/model/channel_layout.dart';
import '../drivers/electrobright/eb_session.dart';
import '../drivers/electrobright/eb_types.dart';

/// Short, self-restoring light shows used to find or check a light.
extension EbRituals on EbSession {
  /// Blinks the light three times, then restores its look (and sleep).
  Future<void> identify() async {
    if (phase != EbPhase.ready) return;
    final int brightness = view.state.scene.brightness;
    final bool wasAsleep = view.state.sleeping;
    beginGesture(EbKeys.brightness);
    for (int i = 0; i < 3; i++) {
      setBrightness(255, live: true);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      setBrightness(0, live: true);
      await Future<void>.delayed(const Duration(milliseconds: 220));
    }
    setBrightness(brightness > 0 ? brightness : 255, live: true);
    endGesture(EbKeys.brightness);
    if (wasAsleep) await setPower(on: false);
  }

  /// Lights each LED on its own in turn (1.2 s each), then restores the
  /// light's colour, brightness and mode. [onChannel] reports the LED lit.
  Future<void> channelTest({void Function(int channel)? onChannel}) async {
    if (phase != EbPhase.ready) return;
    final ChannelColor colour = view.state.scene.color;
    final int brightness = view.state.scene.brightness;
    final int mode = view.state.scene.mode;
    final ChannelLayout l = layout;
    if (mode != 1) await setMode(1);
    beginGesture(EbKeys.color);
    for (int i = 0; i < l.n; i++) {
      onChannel?.call(i);
      setLook(
        color: ChannelColor(l, <int>[
          for (int c = 0; c < l.n; c++) c == i ? 255 : 0,
        ]),
        brightness: 255,
        live: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    endGesture(EbKeys.color);
    setLook(color: colour, brightness: brightness);
    if (mode != 1) await setMode(mode);
  }
}
