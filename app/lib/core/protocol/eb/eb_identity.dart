import '../../model/channel_layout.dart';
import '../../model/light_capabilities.dart';
import 'eb_constants.dart';
import 'eb_reply.dart';

/// Why a light cannot be driven.
enum EbIncompatibility {
  /// The original (pre-3.x) firmware: show "Firmware update needed".
  legacyFirmware,

  /// Not an ElectroBright model id at all.
  notElectroBright,

  /// A newer fixture layout this app does not know: "Needs a newer app".
  unknownLayout,

  /// INFO and CAPS disagree about the layout.
  layoutMismatch,

  /// STATUS does not have the layout's shape.
  statusShape,

  /// MODE_SETTINGS / MODES do not describe the 13 known modes.
  modeCount,
}

/// A handshake reply that rules the light out; see [EbIdentity].
final class EbIdentityError implements Exception {
  const EbIdentityError(this.kind, this.reason);
  final EbIncompatibility kind;
  final String reason;
  @override
  String toString() => 'EbIdentityError($kind: $reason)';
}

/// Identifies a light from its handshake replies (docs/protocol.md §2). Pure,
/// so every rule is tested as a table.
abstract final class EbIdentity {
  /// The layout named by the INFO model id (`EB-C3-<LAYOUT>-V<rev>`). Known
  /// right after INFO, so the pipelined STATUS can be parsed with it.
  static ChannelLayout layoutFromModel(String model) {
    if (model == Eb.legacyInfo) {
      throw const EbIdentityError(
        EbIncompatibility.legacyFirmware,
        'original firmware',
      );
    }
    final RegExpMatch? m = Eb.modelPattern.firstMatch(model);
    if (m == null) {
      throw EbIdentityError(EbIncompatibility.notElectroBright, 'model $model');
    }
    final ChannelLayout? layout = ChannelLayout.fromWire(m.group(1)!);
    if (layout == null) {
      throw EbIdentityError(
        EbIncompatibility.unknownLayout,
        'layout ${m.group(1)}',
      );
    }
    return layout;
  }

  /// Checks the rest of the handshake and derives the light's capabilities.
  static LightCapabilities capabilities({
    required ChannelLayout fromModel,
    required EbVersion version,
    required EbCaps caps,
    required int modeSettingsPairs,
  }) {
    if (version.major < Eb.minFirmwareMajor ||
        caps.protocol != Eb.protocolVersion) {
      throw EbIdentityError(
        EbIncompatibility.legacyFirmware,
        'firmware ${version.version}',
      );
    }
    // RGBW firmware 3.4.0 predates the LAYOUT key: its model id implies RGBW.
    final String? stated = caps.layout;
    if (stated == null
        ? fromModel != ChannelLayout.rgbw
        : stated != fromModel.wire) {
      throw EbIdentityError(
        EbIncompatibility.layoutMismatch,
        'model says ${fromModel.wire}, CAPS says ${stated ?? '(none)'}',
      );
    }
    if (modeSettingsPairs != Eb.numModes) {
      throw EbIdentityError(
        EbIncompatibility.modeCount,
        '$modeSettingsPairs slider pairs',
      );
    }
    final int mask = caps.hasModes ? (caps.modesMask ?? 0) : Eb.allModesMask;
    if (mask == 0 || mask > Eb.allModesMask) {
      throw EbIdentityError(
        EbIncompatibility.modeCount,
        'MODES=${caps.fields['MODES']}',
      );
    }
    return LightCapabilities(
      layout: fromModel,
      modeMask: mask,
      modeCount: Eb.numModes,
      // Firmware before 3.6.0 announces no count: assume the current one.
      presetSlots: (caps.presetSlots ?? Eb.numPresets).clamp(1, Eb.numPresets),
      supportsIdentify: caps.identify,
    );
  }
}
