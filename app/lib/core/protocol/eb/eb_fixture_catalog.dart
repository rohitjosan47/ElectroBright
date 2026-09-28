import 'package:meta/meta.dart';

import '../../color/led_white_points.dart';
import '../../model/channel_color.dart';
import '../../model/channel_layout.dart';

/// One ElectroBright fixture type, as the firmware's profile table defines it
/// (`firmware/core/ElectroBrightCore/src/fixture/Profiles.h`; since 3.7.0 one
/// universal image holds every type and the light stores its own). The
/// cross-repo tests keep every entry equal to the firmware, except
/// [whitePoints] (app-only product data).
@immutable
final class EbFixtureSpec {
  const EbFixtureSpec({
    required this.folder,
    required this.fwsimName,
    required this.layout,
    required this.modelId,
    required this.bleName,
    required this.capsReply,
    required this.modeMask,
    required this.colorValues,
    required this.policeAValues,
    required this.policeBValues,
    required this.legacyFrames,
    this.whitePoints = const LedWhitePoints(),
  });

  /// Sketch folder under firmware/fixtures/: installs the universal firmware
  /// with this type as a new light's default.
  final String folder;

  /// `fwsim --fixture` name.
  final String fwsimName;
  final ChannelLayout layout;
  final String modelId;
  final String bleName;
  final String capsReply;

  /// Supported modes (bit m-1); 0x1FFF = all 13.
  final int modeMask;
  final List<int> colorValues;
  final List<int> policeAValues;
  final List<int> policeBValues;

  /// Also accepts the pre-3.x 7- and 6-byte RGBW frames.
  final bool legacyFrames;

  /// The product's white LED temperatures (app-only: the firmware drives raw
  /// levels). Every saved light of this model uses them for Kelvin ranges,
  /// warm/cool mixing and previews.
  final LedWhitePoints whitePoints;

  /// Power-up / factory-reset colours.
  ChannelColor get color => ChannelColor(layout, colorValues);
  ChannelColor get policeA => ChannelColor(layout, policeAValues);
  ChannelColor get policeB => ChannelColor(layout, policeBValues);

  @override
  String toString() => 'EbFixtureSpec($modelId)';
}

/// Every fixture type of the universal firmware (docs/protocol.md), in CAPS
/// `TYPES=` order.
abstract final class EbFixtureCatalog {
  static const EbFixtureSpec rgbw = EbFixtureSpec(
    folder: 'ElectroBright_RGBW',
    fwsimName: 'rgbw',
    layout: ChannelLayout.rgbw,
    modelId: 'EB-C3-RGBW-V1',
    bleName: 'ElectroBright_C3_V1',
    capsReply: 'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=RGBW',
    modeMask: 0x1FFF,
    colorValues: <int>[255, 255, 255, 0],
    policeAValues: <int>[255, 165, 0, 0],
    policeBValues: <int>[0, 0, 0, 255],
    legacyFrames: true,
    whitePoints: LedWhitePoints(wK: 4000),
  );

  static const EbFixtureSpec rgb = EbFixtureSpec(
    folder: 'ElectroBright_RGB',
    fwsimName: 'rgb',
    layout: ChannelLayout.rgb,
    modelId: 'EB-C3-RGB-V1',
    bleName: 'ElectroBright_C3_RGB_V1',
    capsReply: 'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=RGB',
    modeMask: 0x1FFF,
    colorValues: <int>[255, 255, 255],
    policeAValues: <int>[255, 165, 0],
    policeBValues: <int>[255, 255, 255],
    legacyFrames: false,
    // No white LED.
    whitePoints: LedWhitePoints(),
  );

  static const EbFixtureSpec rgbcct = EbFixtureSpec(
    folder: 'ElectroBright_RGBCCT',
    fwsimName: 'rgbcct',
    layout: ChannelLayout.rgbcct,
    modelId: 'EB-C3-RGBCCT-V1',
    bleName: 'ElectroBright_C3_RGBCCT_V1',
    capsReply: 'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=RGBCCT',
    modeMask: 0x1FFF,
    colorValues: <int>[0, 0, 0, 255, 255],
    policeAValues: <int>[255, 165, 0, 0, 0],
    policeBValues: <int>[0, 0, 0, 255, 255],
    legacyFrames: false,
    whitePoints: LedWhitePoints(cwK: 6500, wwK: 2700),
  );

  static const EbFixtureSpec cct = EbFixtureSpec(
    folder: 'ElectroBright_CCT',
    fwsimName: 'cct',
    layout: ChannelLayout.cct,
    modelId: 'EB-C3-CCT-V1',
    bleName: 'ElectroBright_C3_CCT_V1',
    capsReply: 'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=CCT',
    modeMask: 0x1FFF,
    colorValues: <int>[255, 255],
    policeAValues: <int>[0, 255],
    policeBValues: <int>[255, 0],
    legacyFrames: false,
    whitePoints: LedWhitePoints(cwK: 6500, wwK: 2700),
  );

  static const EbFixtureSpec w = EbFixtureSpec(
    folder: 'ElectroBright_W',
    fwsimName: 'w',
    layout: ChannelLayout.w,
    modelId: 'EB-C3-W-V1',
    bleName: 'ElectroBright_C3_W_V1',
    capsReply: 'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=W,MODES=1DFF',
    modeMask: 0x1DFF,
    colorValues: <int>[255],
    policeAValues: <int>[255],
    policeBValues: <int>[255],
    legacyFrames: false,
    whitePoints: LedWhitePoints(wK: 4000),
  );

  static const List<EbFixtureSpec> all = <EbFixtureSpec>[
    rgbw,
    rgb,
    rgbcct,
    cct,
    w,
  ];

  /// The type SET_TYPE / CAPS `TYPES=` call [wire] (e.g. RGBCCT); null when
  /// unknown.
  static EbFixtureSpec? forType(String wire) {
    for (final EbFixtureSpec f in all) {
      if (f.layout.wire == wire) return f;
    }
    return null;
  }

  static EbFixtureSpec forLayout(ChannelLayout layout) =>
      all.firstWhere((EbFixtureSpec f) => f.layout == layout);

  /// The fixture with INFO model id [modelId] (null: unknown or none).
  static EbFixtureSpec? forModel(String? modelId) {
    for (final EbFixtureSpec f in all) {
      if (f.modelId == modelId) return f;
    }
    return null;
  }

  /// White LED temperatures of a light: its model's, else (model not known
  /// yet, or not in the catalog) its layout's.
  static LedWhitePoints whitePointsFor({
    String? modelId,
    required ChannelLayout layout,
  }) => forModel(modelId)?.whitePoints ?? forLayout(layout).whitePoints;

  static final RegExp _bleName = RegExp(
    r'^ElectroBright_C3_(?:([A-Z]+)_)?V\d+$',
  );

  /// The layout an advertised name suggests (a hint until INFO confirms it):
  /// `ElectroBright_C3_V1` is the RGBW light, `ElectroBright_C3_<L>_V1` the rest.
  static ChannelLayout? layoutFromBleName(String? name) {
    if (name == null) return null;
    final RegExpMatch? m = _bleName.firstMatch(name);
    if (m == null) return null;
    final String? segment = m.group(1);
    return segment == null
        ? ChannelLayout.rgbw
        : ChannelLayout.fromWire(segment);
  }
}
