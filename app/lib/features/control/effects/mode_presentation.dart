import '../../../core/color/color_science.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_tone.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../l10n/app_localizations.dart';

/// A mode as this light shows it: only modes the light supports, with copy
/// in the user's language that matches its LEDs (e.g. on a tunable-white
/// light Rainbow is a temperature sweep, and effect colours are whites).
EbModeSpec presentMode(
  EbModeSpec m,
  ChannelLayout layout,
  LedWhitePoints wp,
  AppLocalizations l,
) {
  final List<int> gradient = layout.hasColour
      ? m.gradient
      : <int>[
          for (final int c in m.gradient)
            ColorScience.toArgb(
              LayoutPreview.render(
                ColorScience.fromArgb(c),
                layout,
                wp,
              ).normalized(),
            ),
        ];
  final bool tunable = layout.white == WhiteKind.tunable;
  return EbModeSpec(
    id: m.id,
    name: modeName(m, layout, l),
    description: switch (m.glyph) {
      EbModeGlyph.rainbow when tunable && !layout.hasColour =>
        l.modeTemperatureSweepDesc,
      EbModeGlyph.tv when !layout.hasColour => l.modeTvWhites,
      _ => _description(m.glyph, l),
    },
    hasSpeed: m.hasSpeed,
    hasFrequency: m.hasFrequency,
    colorUse: m.colorUse,
    gradient: gradient,
    glyph: m.glyph,
    colorModeKind: m.colorModeKind,
    speedLabel: m.speedLabel == null ? null : _speedLabel(m.glyph, l),
    frequencyLabel: m.frequencyLabel == null
        ? null
        : _frequencyLabel(m.glyph, l),
  );
}

/// The name of mode [m] as a light of [layout] shows it.
String modeName(EbModeSpec m, ChannelLayout layout, AppLocalizations l) =>
    switch (m.glyph) {
      EbModeGlyph.rainbow
          when layout.white == WhiteKind.tunable && !layout.hasColour =>
        l.modeTemperatureSweep,
      EbModeGlyph.solid => l.modeSolidName,
      EbModeGlyph.blink => l.modeBlinkName,
      EbModeGlyph.breath => l.modeBreathName,
      EbModeGlyph.fireworks => l.modeFireworksName,
      EbModeGlyph.tv => l.modeTvName,
      EbModeGlyph.thunder => l.modeThunderName,
      EbModeGlyph.faulty => l.modeFaultyName,
      EbModeGlyph.welding => l.modeWeldingName,
      EbModeGlyph.club => l.modeClubName,
      EbModeGlyph.rainbow => l.modeRainbowName,
      EbModeGlyph.fire => l.modeFireName,
      EbModeGlyph.police => l.modePoliceName,
      EbModeGlyph.candle => l.modeCandleName,
    };

String _description(EbModeGlyph g, AppLocalizations l) => switch (g) {
  EbModeGlyph.solid => l.modeSolidDesc,
  EbModeGlyph.blink => l.modeBlinkDesc,
  EbModeGlyph.breath => l.modeBreathDesc,
  EbModeGlyph.fireworks => l.modeFireworksDesc,
  EbModeGlyph.tv => l.modeTvDesc,
  EbModeGlyph.thunder => l.modeThunderDesc,
  EbModeGlyph.faulty => l.modeFaultyDesc,
  EbModeGlyph.welding => l.modeWeldingDesc,
  EbModeGlyph.club => l.modeClubDesc,
  EbModeGlyph.rainbow => l.modeRainbowDesc,
  EbModeGlyph.fire => l.modeFireDesc,
  EbModeGlyph.police => l.modePoliceDesc,
  EbModeGlyph.candle => l.modeCandleDesc,
};

String _speedLabel(EbModeGlyph g, AppLocalizations l) => switch (g) {
  EbModeGlyph.breath => l.sliderBreathShape,
  EbModeGlyph.fireworks => l.sliderBurstSpeed,
  EbModeGlyph.tv => l.sliderScenePace,
  EbModeGlyph.thunder => l.sliderStrokeTempo,
  EbModeGlyph.faulty => l.sliderGlitchSpeed,
  EbModeGlyph.welding => l.sliderWeldLength,
  EbModeGlyph.club => l.sliderTempo,
  EbModeGlyph.fire || EbModeGlyph.candle => l.sliderFlickerSpeed,
  EbModeGlyph.police => l.sliderFlashSpeed,
  _ => l.speed,
};

String _frequencyLabel(EbModeGlyph g, AppLocalizations l) => switch (g) {
  EbModeGlyph.blink => l.sliderBlinkRate,
  EbModeGlyph.breath => l.sliderBreathingRate,
  EbModeGlyph.fireworks => l.sliderLaunchRate,
  EbModeGlyph.tv => l.sliderCutsFlicker,
  EbModeGlyph.thunder => l.sliderStrikeRate,
  EbModeGlyph.faulty => l.sliderGlitchRate,
  EbModeGlyph.welding => l.sliderWeldGap,
  EbModeGlyph.club => l.sliderEnergy,
  EbModeGlyph.rainbow => l.sliderCycleSpeed,
  EbModeGlyph.fire => l.sliderFlameIntensity,
  EbModeGlyph.police => l.sliderFlashesPerSide,
  EbModeGlyph.candle => l.sliderFlickerDepth,
  _ => l.frequency,
};

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
