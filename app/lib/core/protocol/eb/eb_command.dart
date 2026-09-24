import 'package:meta/meta.dart';

import '../../model/channel_color.dart';
import 'eb_constants.dart';
import 'eb_scene.dart';

/// What the firmware answers to a command (see reply_grammar.dart).
enum EbExpect {
  /// `OK`, or `ERROR:<code>` (never STORAGE).
  ok,

  /// Optional `ERROR:STORAGE` (a warning, once per boot), then `OK`.
  okStorageNote,

  /// `OK`, `ERROR:PRESET_ID`, or `ERROR:STORAGE` (provisional: an unsolicited
  /// background STORAGE error may precede a real `OK`).
  okStorageProvisional,

  /// `STATUS` with sleeping=0, `ERROR:PRESET_EMPTY:<id>` or `ERROR:PRESET_ID`.
  presetLoad,
  info,
  version,
  caps,
  status,
  modeSettings,
  presets,
  capabilities,
  diag,
}

/// A text command, range-checked at construction so the firmware never has to
/// report a format error (which also buzzes). Colour and brightness are never
/// text commands: they travel in binary frames (stream lane).
@immutable
sealed class EbCommand {
  const EbCommand();

  /// The command line without its terminator.
  String get wire;
  EbExpect get expect;

  /// Queued commands with the same key collapse to the newest.
  String? get mergeKey => null;

  /// Never merged across; the queue does not reorder around it.
  bool get isBarrier => false;

  /// Latest colour/brightness must reach the device before this executes.
  bool get needsFence => false;

  /// No colour frames may be sent while this is in flight.
  bool get holdsStream => false;

  /// Safe to resend after a timeout.
  bool get idempotent => true;

  /// Typed reply; may be pipelined with other queries.
  bool get isQuery => false;

  Duration get timeout => const Duration(milliseconds: 1500);

  @override
  String toString() => wire;
}

void _range(int v, int lo, int hi, String name) {
  if (v < lo || v > hi) throw RangeError.range(v, lo, hi, name);
}

// ---- Queries (typed replies) ----------------------------------------------------

sealed class EbQuery extends EbCommand {
  const EbQuery();
  @override
  bool get isQuery => true;
}

final class InfoQuery extends EbQuery {
  const InfoQuery();
  @override
  String get wire => 'INFO';
  @override
  EbExpect get expect => EbExpect.info;
}

final class VersionQuery extends EbQuery {
  const VersionQuery();
  @override
  String get wire => 'VERSION';
  @override
  EbExpect get expect => EbExpect.version;
}

final class CapsQuery extends EbQuery {
  const CapsQuery();
  @override
  String get wire => 'CAPS';
  @override
  EbExpect get expect => EbExpect.caps;
}

final class StatusQuery extends EbQuery {
  const StatusQuery();
  @override
  String get wire => 'STATUS';
  @override
  EbExpect get expect => EbExpect.status;
}

final class ModeSettingsQuery extends EbQuery {
  const ModeSettingsQuery();
  @override
  String get wire => 'MODE_SETTINGS';
  @override
  EbExpect get expect => EbExpect.modeSettings;
}

final class PresetListQuery extends EbQuery {
  const PresetListQuery();
  @override
  String get wire => 'PRESET_LIST';
  @override
  EbExpect get expect => EbExpect.presets;
}

final class ModeCapabilitiesQuery extends EbQuery {
  ModeCapabilitiesQuery(this.mode) {
    _range(mode, 1, Eb.numModes, 'mode');
  }
  final int mode;
  @override
  String get wire => 'MODE_CAPABILITIES:$mode';
  @override
  EbExpect get expect => EbExpect.capabilities;
}

final class DiagQuery extends EbQuery {
  const DiagQuery();
  @override
  String get wire => 'DIAG';
  @override
  EbExpect get expect => EbExpect.diag;
}

// ---- Settings ---------------------------------------------------------------------

final class SetMode extends EbCommand {
  SetMode(this.mode) {
    _range(mode, 1, Eb.numModes, 'mode');
  }
  final int mode;
  @override
  String get wire => 'MODE:$mode';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'mode';
}

/// Speed of an explicit mode (never the firmware's implicit "current mode").
final class SetModeSpeed extends EbCommand {
  SetModeSpeed(this.mode, this.value) {
    _range(mode, 1, Eb.numModes, 'mode');
    _range(value, Eb.minLevel, Eb.maxLevel, 'speed');
  }
  final int mode;
  final int value;
  @override
  String get wire => 'MODE_SPEED:$mode,$value';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'speed:$mode';
}

final class SetModeFrequency extends EbCommand {
  SetModeFrequency(this.mode, this.value) {
    _range(mode, 1, Eb.numModes, 'mode');
    _range(value, Eb.minLevel, Eb.maxLevel, 'frequency');
  }
  final int mode;
  final int value;
  @override
  String get wire => 'MODE_FREQUENCY:$mode,$value';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'freq:$mode';
}

final class SetColorMode extends EbCommand {
  SetColorMode(this.kind, this.value) {
    _range(value, 0, 1, 'colorMode');
  }
  final EbColorModeKind kind;
  final int value;
  @override
  String get wire => '${kind.command}:$value';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'colorMode:${kind.name}';
}

final class SetPoliceColor extends EbCommand {
  /// One value per channel of the light's layout (validated by ChannelColor).
  const SetPoliceColor(this.slot, this.color);
  final EbPoliceSlot slot;
  final ChannelColor color;
  @override
  String get wire => '${slot.command}:${color.values.join(',')}';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'police:${slot.name}';
}

/// WAKE or SLEEP (SLEEP also cancels the sleep timer).
final class SetPower extends EbCommand {
  const SetPower({required this.on});
  final bool on;
  @override
  String get wire => on ? 'WAKE' : 'SLEEP';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'power';
}

/// Sleep timer in seconds; 0 cancels. Not idempotent: a resend re-arms it.
final class SetTimer extends EbCommand {
  SetTimer(this.seconds) {
    _range(seconds, 0, Eb.timerMaxSeconds, 'seconds');
  }
  final int seconds;
  @override
  String get wire => 'TIMER:$seconds';
  @override
  EbExpect get expect => EbExpect.ok;
  @override
  String get mergeKey => 'timer';
  @override
  bool get idempotent => false;
}

final class SetSound extends EbCommand {
  const SetSound({required this.on});
  final bool on;
  @override
  String get wire => on ? 'SOUND_ON' : 'SOUND_OFF';
  @override
  EbExpect get expect => EbExpect.okStorageNote;
  @override
  String get mergeKey => 'sound';
}

final class Ping extends EbCommand {
  const Ping();
  @override
  String get wire => 'PING';
  @override
  EbExpect get expect => EbExpect.ok;
}

// ---- Presets and reset (barriers) -----------------------------------------------------

final class PresetSave extends EbCommand {
  PresetSave(this.slot) {
    _range(slot, 0, Eb.numPresets - 1, 'slot');
  }
  final int slot;
  @override
  String get wire => 'PRESET_SAVE:$slot';
  @override
  EbExpect get expect => EbExpect.okStorageProvisional;
  @override
  bool get isBarrier => true;
  @override
  bool get needsFence => true;
  @override
  Duration get timeout => const Duration(seconds: 3);
}

final class PresetDelete extends EbCommand {
  PresetDelete(this.slot) {
    _range(slot, 0, Eb.numPresets - 1, 'slot');
  }
  final int slot;
  @override
  String get wire => 'PRESET_DELETE:$slot';
  @override
  EbExpect get expect => EbExpect.okStorageProvisional;
  @override
  bool get isBarrier => true;
  @override
  Duration get timeout => const Duration(seconds: 3);
}

final class PresetLoad extends EbCommand {
  PresetLoad(this.slot) {
    _range(slot, 0, Eb.numPresets - 1, 'slot');
  }
  final int slot;
  @override
  String get wire => 'PRESET_LOAD:$slot';
  @override
  EbExpect get expect => EbExpect.presetLoad;
  @override
  bool get isBarrier => true;
  @override
  bool get needsFence => true;
  @override
  bool get holdsStream => true;
}

final class FactoryReset extends EbCommand {
  const FactoryReset();
  @override
  String get wire => 'FACTORY_RESET';
  @override
  EbExpect get expect => EbExpect.okStorageNote;
  @override
  bool get isBarrier => true;
  @override
  bool get needsFence => true;
  @override
  bool get holdsStream => true;
  @override
  bool get idempotent => false;
  @override
  Duration get timeout => const Duration(seconds: 4);
}
