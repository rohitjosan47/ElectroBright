import 'package:meta/meta.dart';

import '../protocol/eb/eb_constants.dart';
import 'channel_layout.dart';

/// Which colour controls a light gets (derived from its layout's LEDs).
enum ColourSurface {
  /// One white LED only: intensity is the whole story (W).
  intensity,

  /// Cool + warm white: colour temperature and level (CCT).
  tunableWhite,

  /// RGB colours (RGB).
  colour,

  /// RGB colours plus a white LED (RGBW).
  colourPlusWhite,

  /// RGB colours plus tunable white (RGBCCT).
  colourPlusTunableWhite,
}

/// What a light can do, learned from its firmware (INFO / CAPS /
/// MODE_SETTINGS) and saved with the fixture. Every screen adapts to this.
@immutable
final class LightCapabilities {
  const LightCapabilities({
    required this.layout,
    this.modeMask = allModes,
    this.modeCount = 13,
    this.presetSlots = Eb.numPresets,
    this.hasTimer = true,
    this.hasSound = true,
    this.supportsIdentify = false,
    this.supportsTypeChange = false,
    this.supportsProbe = false,
  });

  /// A light whose firmware has not been read yet (e.g. from its BLE name or
  /// an imported record): layout known, every feature assumed.
  factory LightCapabilities.assumed(ChannelLayout layout) =>
      LightCapabilities(layout: layout);

  static const int allModes = 0x1FFF;

  final ChannelLayout layout;

  /// Bit (m - 1) set = mode m supported (CAPS `MODES=`; all 13 when absent).
  final int modeMask;
  final int modeCount;
  final int presetSlots;
  final bool hasTimer;
  final bool hasSound;

  /// CAPS `IDENTIFY=1` (3.6.1+); false when absent or not read yet.
  final bool supportsIdentify;

  /// CAPS `TYPES=` (3.7.0+): the fixture type can be changed (SET_TYPE);
  /// false when absent or not read yet.
  final bool supportsTypeChange;

  /// CAPS `PROBE=1` (3.7.0+): single LED outputs can be tested (PROBE);
  /// false when absent or not read yet.
  final bool supportsProbe;

  bool supportsMode(int mode) =>
      mode >= 1 && mode <= modeCount && (modeMask >> (mode - 1)) & 1 == 1;

  /// Supported modes, in catalogue order.
  List<int> get modes => <int>[
    for (int m = 1; m <= modeCount; m++)
      if (supportsMode(m)) m,
  ];

  ColourSurface get colourSurface => switch ((layout.hasColour, layout.white)) {
    (false, WhiteKind.tunable) => ColourSurface.tunableWhite,
    (false, _) => ColourSurface.intensity,
    (true, WhiteKind.none) => ColourSurface.colour,
    (true, WhiteKind.single) => ColourSurface.colourPlusWhite,
    (true, WhiteKind.tunable) => ColourSurface.colourPlusTunableWhite,
  };

  Map<String, Object> toJson() => <String, Object>{
    'layout': layout.wire,
    'modeMask': modeMask,
    'modeCount': modeCount,
    'presetSlots': presetSlots,
    'hasTimer': hasTimer,
    'hasSound': hasSound,
    'supportsIdentify': supportsIdentify,
    'supportsTypeChange': supportsTypeChange,
    'supportsProbe': supportsProbe,
  };

  static LightCapabilities? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final ChannelLayout? layout = json['layout'] is String
        ? ChannelLayout.fromWire(json['layout']! as String)
        : null;
    final Object? mask = json['modeMask'];
    final Object? count = json['modeCount'];
    final Object? slots = json['presetSlots'];
    if (layout == null || mask is! int || count is! int || slots is! int) {
      return null;
    }
    if (count < 1 || count > 16 || mask <= 0 || mask >= 1 << count) {
      return null;
    }
    return LightCapabilities(
      layout: layout,
      modeMask: mask,
      modeCount: count,
      // Saved from earlier firmware (25): the app offers no more than now.
      presetSlots: slots.clamp(1, Eb.numPresets),
      hasTimer: json['hasTimer'] != false,
      hasSound: json['hasSound'] != false,
      supportsIdentify: json['supportsIdentify'] == true,
      supportsTypeChange: json['supportsTypeChange'] == true,
      supportsProbe: json['supportsProbe'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LightCapabilities &&
      other.layout == layout &&
      other.modeMask == modeMask &&
      other.modeCount == modeCount &&
      other.presetSlots == presetSlots &&
      other.hasTimer == hasTimer &&
      other.hasSound == hasSound &&
      other.supportsIdentify == supportsIdentify &&
      other.supportsTypeChange == supportsTypeChange &&
      other.supportsProbe == supportsProbe;

  @override
  int get hashCode => Object.hash(
    layout,
    modeMask,
    modeCount,
    presetSlots,
    hasTimer,
    hasSound,
    supportsIdentify,
    supportsTypeChange,
    supportsProbe,
  );

  @override
  String toString() =>
      'LightCapabilities(${layout.wire}, modes 0x${modeMask.toRadixString(16)})';
}
