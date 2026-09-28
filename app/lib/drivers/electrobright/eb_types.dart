import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../core/model/channel_layout.dart';
import '../../core/model/light_capabilities.dart';
import '../../core/protocol/eb/eb_command.dart';
import '../../core/protocol/eb/eb_identity.dart';
import '../../core/protocol/eb/eb_reply.dart';
import '../../core/protocol/eb/eb_scene.dart';

export '../../core/protocol/eb/eb_identity.dart' show EbIncompatibility;

const SetEquality<int> _setEq = SetEquality<int>();

/// The state of one ElectroBright light as the session tracks it.
@immutable
final class EbDeviceState {
  EbDeviceState({
    required this.scene,
    required this.sleeping,
    required this.soundOn,
    required Set<int> presets,
    this.timerDeadline,
  }) : presets = Set<int>.unmodifiable(presets);

  final EbScene scene;
  final bool sleeping;
  final bool soundOn;
  final Set<int> presets;

  /// Scheduler time at which the device's sleep timer fires; null = no timer.
  final Duration? timerDeadline;

  static const Object _keep = Object();

  EbDeviceState copyWith({
    EbScene? scene,
    bool? sleeping,
    bool? soundOn,
    Set<int>? presets,
    Object? timerDeadline = _keep,
  }) => EbDeviceState(
    scene: scene ?? this.scene,
    sleeping: sleeping ?? this.sleeping,
    soundOn: soundOn ?? this.soundOn,
    presets: presets ?? this.presets,
    timerDeadline: identical(timerDeadline, _keep)
        ? this.timerDeadline
        : timerDeadline as Duration?,
  );

  @override
  bool operator ==(Object other) =>
      other is EbDeviceState &&
      other.scene == scene &&
      other.sleeping == sleeping &&
      other.soundOn == soundOn &&
      _setEq.equals(other.presets, presets) &&
      other.timerDeadline == timerDeadline;

  @override
  int get hashCode => Object.hash(
    scene,
    sleeping,
    soundOn,
    _setEq.hash(presets),
    timerDeadline,
  );

  @override
  String toString() =>
      'EbDeviceState($scene sleeping=$sleeping sound=$soundOn '
      'presets=$presets timer=$timerDeadline)';
}

/// Identity and capabilities reported during the handshake.
@immutable
final class EbFirmware {
  const EbFirmware({
    required this.model,
    required this.version,
    required this.caps,
    required this.modeCount,
    required this.capabilities,
    this.wirelessUpdates = false,
  });
  final String model;
  final EbVersion version;
  final EbCaps caps;
  final int modeCount;

  /// What the light can do; every screen adapts to this.
  final LightCapabilities capabilities;

  /// It has the wireless-update service (firmware 3.8.0+).
  final bool wirelessUpdates;

  ChannelLayout get layout => capabilities.layout;
}

enum EbPhase { connecting, handshaking, ready, resyncing, closed }

/// What the UI renders: the app's intended state (confirmed values plus
/// changes the light has not confirmed yet).
@immutable
final class EbView {
  EbView({
    required this.phase,
    required this.state,
    required Set<String> pending,
    this.firmware,
    this.colorOrigin = const EbColorOrigin.light(0),
    Set<String> gestures = const <String>{},
  }) : pending = Set<String>.unmodifiable(pending),
       gestures = Set<String>.unmodifiable(gestures);

  final EbPhase phase;
  final EbDeviceState state;

  /// Where [state]'s colour came from.
  final EbColorOrigin colorOrigin;

  /// Keys (see [EbKeys]) with an unconfirmed change.
  final Set<String> pending;

  /// Keys (see [EbKeys]) a finger is on right now.
  final Set<String> gestures;
  final EbFirmware? firmware;

  Duration? timerRemaining(Duration now) {
    final Duration? d = state.timerDeadline;
    if (d == null) return null;
    final Duration left = d - now;
    return left.isNegative ? Duration.zero : left;
  }
}

/// Where the colour a session shows came from: a change made through the
/// session ([byUser], with the sequence number [EbSession.setColor] returned
/// for it; kept when the light confirms that value), or the light (adopted at
/// a handshake, preset load or resync, or reverted after a lost write).
@immutable
final class EbColorOrigin {
  const EbColorOrigin.user(this.seq) : byUser = true;
  const EbColorOrigin.light(this.seq) : byUser = false;

  final int seq;
  final bool byUser;

  @override
  bool operator ==(Object other) =>
      other is EbColorOrigin && other.seq == seq && other.byUser == byUser;
  @override
  int get hashCode => Object.hash(seq, byUser);
  @override
  String toString() => '${byUser ? 'user' : 'light'}#$seq';
}

/// Reconciliation keys (also the command lane's merge keys).
abstract final class EbKeys {
  static const String color = 'color';
  static const String brightness = 'brightness';
  static const String mode = 'mode';
  static const String power = 'power';
  static const String timer = 'timer';
  static const String sound = 'sound';
  static String speed(int mode) => 'speed:$mode';
  static String frequency(int mode) => 'freq:$mode';
  static String colorMode(EbColorModeKind k) => 'colorMode:${k.name}';
  static String police(EbPoliceSlot s) => 'police:${s.name}';
}

enum EbOutcome {
  /// Confirmed by the light.
  ok,

  /// Not sent: the light already had this value.
  skipped,

  /// Replaced by a newer change to the same setting before it was sent.
  superseded,

  /// Rejected by the light ([EbResult.code] says why).
  failed,

  /// No reply in time (after any retry).
  timedOut,

  /// The link ended before a reply.
  disconnected,
}

@immutable
final class EbResult {
  const EbResult(this.outcome, {this.code, this.reply});
  static const EbResult ok = EbResult(EbOutcome.ok);
  static const EbResult skipped = EbResult(EbOutcome.skipped);
  static const EbResult superseded = EbResult(EbOutcome.superseded);
  static const EbResult timedOut = EbResult(EbOutcome.timedOut);
  static const EbResult disconnected = EbResult(EbOutcome.disconnected);

  final EbOutcome outcome;

  /// Firmware error code for [EbOutcome.failed].
  final String? code;

  /// The final reply line, when there was one.
  final EbReply? reply;

  bool get isSuccess =>
      outcome == EbOutcome.ok ||
      outcome == EbOutcome.skipped ||
      outcome == EbOutcome.superseded;

  @override
  String toString() => code == null ? '$outcome' : '$outcome($code)';
}

/// Things the UI should know about that are not state changes.
@immutable
sealed class EbEvent {
  const EbEvent();
}

/// The light reported it could not write its flash (settings may not survive
/// a power cycle).
final class EbStorageWarning extends EbEvent {
  const EbStorageWarning();
}

final class EbCommandFailed extends EbEvent {
  const EbCommandFailed(this.command, this.result);
  final EbCommand command;
  final EbResult result;
}

/// The light's sleep timer expired and it turned itself off.
final class EbTimerExpired extends EbEvent {
  const EbTimerExpired();
}

/// A resync found the light holding a different value than the app set; the
/// app re-sent its value. Counted in diagnostics.
final class EbDivergence extends EbEvent {
  const EbDivergence(this.key);
  final String key;
}

/// Changes made while the light was unreachable waited their whole window
/// and were dropped (raised by the FixtureSession, once per expiry); the
/// controls are back at the light's real values.
final class EbOfflineChangesExpired extends EbEvent {
  const EbOfflineChangesExpired();
}

/// The light stopped answering; the owner should drop and reconnect the link.
final class EbUnresponsive extends EbEvent {
  const EbUnresponsive();
}

/// The light runs firmware this app cannot drive.
final class EbIncompatible implements Exception {
  const EbIncompatible(this.kind, this.reason);
  final EbIncompatibility kind;
  final String reason;

  /// True for the original ElectroBright firmware: show "update firmware".
  bool get legacy => kind == EbIncompatibility.legacyFirmware;
  @override
  String toString() => 'EbIncompatible(${kind.name}: $reason)';
}

/// The light never answered the handshake.
final class EbNoResponse implements Exception {
  const EbNoResponse();
  @override
  String toString() => 'EbNoResponse';
}
