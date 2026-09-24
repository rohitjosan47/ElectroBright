import '../../../core/color/color_science.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_tone.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../l10n/app_localizations.dart';

/// A mode as this light shows it: only modes the light supports, with copy
/// and colours that match its LEDs (e.g. on a tunable-white light Rainbow is
/// a temperature sweep, and effect colours are whites).
EbModeSpec presentMode(
  EbModeSpec m,
  ChannelLayout layout,
  LedWhitePoints wp,
  AppLocalizations l,
) {
  if (layout.hasColour) return m;
  final List<int> gradient = <int>[
    for (final int c in m.gradient)
      ColorScience.toArgb(
        LayoutPreview.render(ColorScience.fromArgb(c), layout, wp).normalized(),
      ),
  ];
  final bool tunable = layout.white == WhiteKind.tunable;
  return EbModeSpec(
    id: m.id,
    name: tunable && m.glyph == EbModeGlyph.rainbow
        ? l.modeTemperatureSweep
        : m.name,
    description: switch (m.glyph) {
      EbModeGlyph.rainbow when tunable => l.modeTemperatureSweepDesc,
      EbModeGlyph.tv => l.modeTvWhites,
      _ => m.description,
    },
    hasSpeed: m.hasSpeed,
    hasFrequency: m.hasFrequency,
    colorUse: m.colorUse,
    gradient: gradient,
    glyph: m.glyph,
    colorModeKind: m.colorModeKind,
    speedLabel: m.speedLabel,
    frequencyLabel: m.frequencyLabel,
  );
}

/// The modes this light supports, in catalogue order, as it shows them.
List<EbModeSpec> presentModes(
  LightCapabilities caps,
  LedWhitePoints wp,
  AppLocalizations l,
) => <EbModeSpec>[
  for (final EbModeSpec m in EbModeCatalog.modes)
    if (caps.supportsMode(m.id)) presentMode(m, caps.layout, wp, l),
];

/// Labels of the colour-source toggle (value 0, value 1) of modes 4, 9, 12.
(String, String) sourceLabels(
  EbColorModeKind kind,
  ChannelLayout layout,
  AppLocalizations l,
) {
  final bool police = kind == EbColorModeKind.police;
  if (layout.hasColour) {
    return police
        ? (l.sourceYourColours, l.sourceRedBlue)
        : (l.sourceYourColour, l.sourceAutoPalette);
  }
  if (layout.white == WhiteKind.tunable) {
    return police
        ? (l.sourceYourWhite, l.sourceWarmCool)
        : (l.sourceYourWhite, l.sourceAutoWarmCool);
  }
  return (l.sourceYourLevel, l.sourceAutoFlashes);
}
