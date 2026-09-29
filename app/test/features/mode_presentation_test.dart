import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:electrobright/features/control/effects/mode_presentation.dart';
import 'package:electrobright/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mode copy comes from the localisation files; in English it is the
/// catalogue's own (whose slider labels match the firmware's registry).
void main() {
  final AppLocalizations en = lookupAppLocalizations(const Locale('en'));

  test('English mode copy equals the catalogue', () {
    for (final EbModeSpec m in EbModeCatalog.modes) {
      final EbModeSpec shown = presentMode(
        m,
        ChannelLayout.rgbw,
        const LedWhitePoints(),
        en,
      );
      expect(shown.name, m.name);
      expect(shown.description, m.description, reason: m.name);
      expect(shown.speedLabel, m.speedLabel, reason: m.name);
      expect(shown.frequencyLabel, m.frequencyLabel, reason: m.name);
      expect(shown.gradient, m.gradient, reason: m.name);
    }
  });

  test('a tunable-white light shows Rainbow as a temperature sweep', () {
    final EbModeSpec rainbow = EbModeCatalog.modes.firstWhere(
      (EbModeSpec m) => m.glyph == EbModeGlyph.rainbow,
    );
    expect(modeName(rainbow, ChannelLayout.cct, en), en.modeTemperatureSweep);
    expect(modeName(rainbow, ChannelLayout.rgbcct, en), en.modeRainbowName);
  });
}
