import 'package:meta/meta.dart';

import 'eb_scene.dart';

/// Whether an effect is drawn in the user's picked base colour.
enum EbColorUse {
  /// Always uses the picked colour.
  always,

  /// Uses the picked colour only when its colour mode is 0 (manual).
  whenManual,

  /// Has its own colours (TV, Rainbow, Police).
  never,
}

/// Identifies the animated glyph painter for a mode tile.
enum EbModeGlyph {
  solid,
  blink,
  breath,
  fireworks,
  tv,
  thunder,
  faulty,
  welding,
  club,
  rainbow,
  fire,
  police,
  candle,
}

/// One lighting mode of the ElectroBright firmware. Capability flags and
/// slider labels must equal firmware/core/ElectroBrightCore/src/render/ModeRegistry.h
/// (enforced by test/cross_repo/mode_registry_sync_test.dart).
@immutable
final class EbModeSpec {
  const EbModeSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.hasSpeed,
    required this.hasFrequency,
    required this.colorUse,
    required this.gradient,
    required this.glyph,
    this.colorModeKind,
    this.speedLabel,
    this.frequencyLabel,
  });

  final int id;
  final String name;
  final String description;
  final bool hasSpeed;
  final bool hasFrequency;
  final EbColorModeKind? colorModeKind;
  final String? speedLabel;
  final String? frequencyLabel;
  final EbColorUse colorUse;

  /// Accent gradient as ARGB values (UI layer converts to colours).
  final List<int> gradient;
  final EbModeGlyph glyph;

  bool get hasColorMode => colorModeKind != null;
}

abstract final class EbModeCatalog {
  static const List<EbModeSpec> modes = <EbModeSpec>[
    EbModeSpec(
      id: 1,
      name: 'Solid Color',
      description: 'Steady light in your colour',
      hasSpeed: false,
      hasFrequency: false,
      colorUse: EbColorUse.always,
      gradient: <int>[0xFF00E5FF, 0xFF0072FF],
      glyph: EbModeGlyph.solid,
    ),
    EbModeSpec(
      id: 2,
      name: 'Blink',
      description: 'A crisp on/off pulse',
      hasSpeed: false,
      hasFrequency: true,
      frequencyLabel: 'Blink Rate',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFFFFEA00, 0xFFFF9100],
      glyph: EbModeGlyph.blink,
    ),
    EbModeSpec(
      id: 3,
      name: 'Breath',
      description: 'Slow, organic breathing',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Breath Shape',
      frequencyLabel: 'Breathing Rate',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFF00F5A0, 0xFF00D9F5],
      glyph: EbModeGlyph.breath,
    ),
    EbModeSpec(
      id: 4,
      name: 'Fireworks',
      description: 'Rockets, bursts and crackle',
      hasSpeed: true,
      hasFrequency: true,
      colorModeKind: EbColorModeKind.firework,
      speedLabel: 'Burst Speed',
      frequencyLabel: 'Launch Rate',
      colorUse: EbColorUse.whenManual,
      gradient: <int>[0xFFFF0055, 0xFFFFAA00],
      glyph: EbModeGlyph.fireworks,
    ),
    EbModeSpec(
      id: 5,
      name: 'TV Simulator',
      description: 'The flicker of a TV in a dark room',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Scene Pace',
      frequencyLabel: 'Cuts & Flicker',
      colorUse: EbColorUse.never,
      gradient: <int>[0xFF7000FF, 0xFF00E5FF],
      glyph: EbModeGlyph.tv,
    ),
    EbModeSpec(
      id: 6,
      name: 'Thunderstorm',
      description: 'Lightning with real strike patterns',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Stroke Tempo',
      frequencyLabel: 'Strike Rate',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFF2979FF, 0xFFD500F9],
      glyph: EbModeGlyph.thunder,
    ),
    EbModeSpec(
      id: 7,
      name: 'Faulty Bulb',
      description: 'A failing tube that sputters',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Glitch Speed',
      frequencyLabel: 'Glitch Rate',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFFFF9100, 0xFFFF1744],
      glyph: EbModeGlyph.faulty,
    ),
    EbModeSpec(
      id: 8,
      name: 'Welding',
      description: 'Arc, sparks and a glowing bead',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Weld Length',
      frequencyLabel: 'Weld Gap',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFFFF6D00, 0xFF00B0FF],
      glyph: EbModeGlyph.welding,
    ),
    EbModeSpec(
      id: 9,
      name: 'Club Lights',
      description: 'Rhythmic strobes and colour',
      hasSpeed: true,
      hasFrequency: true,
      colorModeKind: EbColorModeKind.club,
      speedLabel: 'Tempo',
      frequencyLabel: 'Energy',
      colorUse: EbColorUse.whenManual,
      gradient: <int>[0xFFFF007F, 0xFF7928CA],
      glyph: EbModeGlyph.club,
    ),
    EbModeSpec(
      id: 10,
      name: 'Rainbow',
      description: 'An endless flow through the spectrum',
      hasSpeed: false,
      hasFrequency: true,
      frequencyLabel: 'Cycle Speed',
      colorUse: EbColorUse.never,
      gradient: <int>[
        0xFFFF0000,
        0xFFFFEA00,
        0xFF00FF00,
        0xFF00E5FF,
        0xFF7000FF,
      ],
      glyph: EbModeGlyph.rainbow,
    ),
    EbModeSpec(
      id: 11,
      name: 'Fire',
      description: 'A living hearth fire',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Flicker Speed',
      frequencyLabel: 'Flame Intensity',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFFFF1744, 0xFFFF9100],
      glyph: EbModeGlyph.fire,
    ),
    EbModeSpec(
      id: 12,
      name: 'Police Strobe',
      description: 'Emergency wig-wag beacons',
      hasSpeed: true,
      hasFrequency: true,
      colorModeKind: EbColorModeKind.police,
      speedLabel: 'Flash Speed',
      frequencyLabel: 'Flashes per Side',
      colorUse: EbColorUse.never,
      gradient: <int>[0xFFFF0044, 0xFF0066FF],
      glyph: EbModeGlyph.police,
    ),
    EbModeSpec(
      id: 13,
      name: 'Candle',
      description: 'A gentle wick in a draught',
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Flicker Speed',
      frequencyLabel: 'Flicker Depth',
      colorUse: EbColorUse.always,
      gradient: <int>[0xFFFF9E00, 0xFFFF5E00],
      glyph: EbModeGlyph.candle,
    ),
  ];

  static EbModeSpec byId(int id) =>
      modes[(id < 1 || id > modes.length ? 1 : id) - 1];

  /// Whether the light currently shows the picked base colour.
  static bool usesPickedColor(EbScene scene) {
    final EbModeSpec m = byId(scene.mode);
    return switch (m.colorUse) {
      EbColorUse.always => true,
      EbColorUse.never => false,
      EbColorUse.whenManual => scene.colorMode(m.colorModeKind!) == 0,
    };
  }
}
