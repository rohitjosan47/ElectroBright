import 'dart:async';

import 'package:meta/meta.dart';

import '../core/ble/ble_link.dart';
import '../core/color/colour_engine.dart';
import '../core/model/fixture.dart';
import '../core/model/channel_color.dart';
import '../core/protocol/eb/eb_scene.dart';
import '../core/util/scheduler.dart';
import '../drivers/electrobright/eb_session.dart';
import '../drivers/electrobright/eb_types.dart';

/// Where a light is in its connection life.
enum LinkPhase {
  /// Not wanted: not connected, nothing pending.
  idle,

  /// Wanted, waiting to be seen advertising / for a connect slot / backoff.
  waiting,
  connecting,
  handshaking,
  ready,

  /// Wanted but not found: off, out of range, or connected to another phone
  /// (the firmware stops advertising while connected, so these look alike).
  unavailable,

  /// Firmware this app cannot drive; [FixtureStatus.legacyFirmware] = update.
  incompatible,

  /// Bluetooth off or not permitted.
  bluetoothOff,
}

/// Everything the UI needs about one light.
@immutable
final class FixtureStatus {
  const FixtureStatus({
    required this.phase,
    this.view,
    this.lastKnown,
    this.attempt = 0,
    this.incompatibility,
    this.detail,
    this.offlineBrightness,
    this.colourPick,
  });

  final LinkPhase phase;

  /// Live session view while connected.
  final EbView? view;

  /// The last confirmed state (shown dimmed while not connected).
  final EbDeviceState? lastKnown;
  final int attempt;

  /// Why the light cannot be driven (phase [LinkPhase.incompatible]).
  final EbIncompatibility? incompatibility;
  final String? detail;

  /// The original firmware: show "Firmware update needed".
  bool get legacyFirmware =>
      incompatibility == EbIncompatibility.legacyFirmware;

  bool get isReady => phase == LinkPhase.ready && view != null;

  /// Brightness set while not connected, sent when the light is back
  /// (0 = turned off at zero). Shown instead of the last known one, so the
  /// control keeps what the user chose.
  final int? offlineBrightness;

  /// What was last picked on this phone (the editor's intent, before 8-bit
  /// encoding) and the session change that sent it. It is what the colour
  /// shown is while [view]'s colour origin is that change.
  final ColourPick? colourPick;

  /// What the UI should render: live when connected, else the last known
  /// with the change waiting to be sent.
  EbDeviceState? get state {
    final EbView? v = view;
    if (v != null) return v.state;
    final EbDeviceState? s = lastKnown;
    final int? b = offlineBrightness;
    if (s == null || b == null) return s;
    return b == 0
        ? s.copyWith(sleeping: true)
        : s.copyWith(scene: s.scene.copyWith(brightness: b), sleeping: false);
  }

  /// The same status: every field equal, and the very same live [view]
  /// (a new view is always news).
  @override
  bool operator ==(Object other) =>
      other is FixtureStatus &&
      other.phase == phase &&
      identical(other.view, view) &&
      other.lastKnown == lastKnown &&
      other.attempt == attempt &&
      other.incompatibility == incompatibility &&
      other.detail == detail &&
      other.offlineBrightness == offlineBrightness &&
      other.colourPick == colourPick;

  @override
  int get hashCode => Object.hash(
    phase,
    identityHashCode(view),
    lastKnown,
    attempt,
    incompatibility,
    detail,
    offlineBrightness,
    colourPick,
  );

  FixtureStatus _withOffline(int? brightness) => FixtureStatus(
    phase: phase,
    view: view,
    lastKnown: lastKnown,
    attempt: attempt,
    incompatibility: incompatibility,
    detail: detail,
    offlineBrightness: view == null ? brightness : null,
    colourPick: colourPick,
  );

  FixtureStatus _withPick(ColourPick? pick) => FixtureStatus(
    phase: phase,
    view: view,
    lastKnown: lastKnown,
    attempt: attempt,
    incompatibility: incompatibility,
    detail: detail,
    offlineBrightness: offlineBrightness,
    colourPick: view == null ? null : pick,
  );
}

/// A colour picked on this phone: the intent and the session change
/// ([EbColorOrigin.seq]) that sent its encoding.
@immutable
final class ColourPick {
  const ColourPick(this.seq, this.intent);
  final int seq;
  final ColourIntent intent;

  @override
  bool operator ==(Object other) =>
      other is ColourPick && other.seq == seq && other.intent == intent;
  @override
  int get hashCode => Object.hash(seq, intent);
  @override
  String toString() => 'ColourPick#$seq($intent)';
}

/// Who asked for a change to a light's look.
enum CommandOrigin {
  /// The user, on this light's own controls.
  user,

  /// A group (Colour lights or White lights).
  group,

  /// The app itself: identify, channel test, catch-up, resync.
  system,
}

/// One saved light: its (optional) live driver session plus the last-known
/// state and short-lived offline changes. Owned by the ConnectionManager.
final class FixtureSession {
  FixtureSession(this.fixture, {required this._scheduler});

  Fixture fixture;
  final Scheduler _scheduler;

  /// How long a change made while the light is unreachable waits for it.
  /// Then it is dropped, the controls glide back to the light's real values
  /// and one message says so (EbOfflineChangesExpired). Kept in memory only:
  /// an app restart drops pending changes.
  static const Duration offlineWindow = Duration(seconds: 60);

  /// Fires when the oldest pending offline change runs out of time.
  Cancelable? _expiry;

  /// The colour last picked on this phone, unquantised, and the session
  /// change that sent it (see [FixtureStatus.colourPick]).
  ColourPick? _pick;

  /// Brightness set while not connected (see [FixtureStatus.offlineBrightness]).
  int? _offlineBrightness;

  /// Released at 0 and the link dropped before the level to wake to reached
  /// the light: stored after the next handshake if it is still asleep at 0.
  int? _pendingWake;

  FixtureStatus _status = const FixtureStatus(phase: LinkPhase.idle);
  final StreamController<FixtureStatus> _statuses =
      StreamController<FixtureStatus>.broadcast();
  final StreamController<EbEvent> _events =
      StreamController<EbEvent>.broadcast();
  final StreamController<String> _userLook = StreamController<String>.broadcast(
    sync: true,
  );
  EbSession? _session;
  StreamSubscription<EbView>? _viewSub;
  StreamSubscription<EbEvent>? _eventSub;

  /// Offline changes per setting: when made, how long to keep, the action.
  final Map<String, (Duration, Duration, void Function(EbSession))> _offline =
      <String, (Duration, Duration, void Function(EbSession))>{};

  /// Time source of the session (timed rituals use it too).
  Scheduler get scheduler => _scheduler;

  FixtureStatus get status => _status;
  Stream<FixtureStatus> get statuses => _statuses.stream;
  Stream<EbEvent> get events => _events.stream;

  /// The setting ([EbKeys]) of each look change the user makes on this
  /// light's own controls (not a group, not the app's own writes), as it
  /// is made, also while the light is reconnecting.
  Stream<String> get userLookChanges => _userLook.stream;

  void _byUser(CommandOrigin origin, String key) {
    if (origin == CommandOrigin.user && !_userLook.isClosed) {
      _userLook.add(key);
    }
  }

  EbSession? get session => _session;

  /// Shows [state] (saved from an earlier connection) until the light is
  /// connected; ignored when it is for another layout or the light is live.
  void seedLastKnown(EbDeviceState state) {
    if (_status.phase == LinkPhase.ready) return;
    if (state.scene.layout != fixture.layout) return;
    _set(
      FixtureStatus(
        phase: _status.phase,
        lastKnown: state,
        attempt: _status.attempt,
        incompatibility: _status.incompatibility,
        detail: _status.detail,
      ),
    );
  }

  void setPhase(
    LinkPhase phase, {
    int? attempt,
    EbIncompatibility? incompatibility,
    String? detail,
  }) {
    if (phase == LinkPhase.incompatible) {
      _setupNeeded =
          (incompatibility ?? _status.incompatibility) ==
          EbIncompatibility.setupNeeded;
    } else if (phase == LinkPhase.ready) {
      _setupNeeded = false;
    }
    _set(
      FixtureStatus(
        phase: phase,
        view: phase == LinkPhase.ready ? _session?.view : null,
        lastKnown: _status.lastKnown,
        attempt: attempt ?? _status.attempt,
        incompatibility: phase == LinkPhase.incompatible
            ? incompatibility ?? _status.incompatibility
            : null,
        detail: detail,
      ),
    );
  }

  /// The light last reported setup-needed mode (no fixture type): the next
  /// handshake starts with CAPS, which that mode accepts, instead of INFO.
  bool _setupNeeded = false;

  /// Takes over a fresh link: handshake, then replay recent offline changes.
  /// Throws what [EbSession.start] throws (the caller decides on retries).
  /// [setupFirst]: the light advertises setup-needed mode ([Eb.setupName]).
  Future<void> attach(
    BleLink link, {
    EbSessionOptions? options,
    bool setupFirst = false,
  }) async {
    await _detach();
    final EbSession s = EbSession(
      link: link,
      scheduler: _scheduler,
      options: options ?? const EbSessionOptions(),
      expectedLayout: fixture.layout,
    );
    _session = s;
    // Sequence numbers belong to a session.
    _pick = null;
    setPhase(LinkPhase.handshaking);
    try {
      await s.start(setupFirst: setupFirst || _setupNeeded);
    } on Object {
      await _detach();
      rethrow;
    }
    _viewSub = s.views.listen((EbView v) {
      if (v.phase == EbPhase.closed) return;
      _set(
        FixtureStatus(
          phase: LinkPhase.ready,
          view: v,
          lastKnown: s.confirmed,
          attempt: 0,
        ),
      );
    });
    _eventSub = s.events.listen(_events.add);
    _set(
      FixtureStatus(
        phase: LinkPhase.ready,
        view: s.view,
        lastKnown: s.confirmed,
      ),
    );
    _replayOffline(s);
    _offlineBrightness = null;
    final int? wake = _pendingWake;
    _pendingWake = null;
    if (wake != null) s.storeWakeBrightness(wake);
  }

  /// The link ended (the manager already knows).
  Future<void> linkClosed() async {
    final EbSession? s = _session;
    _pendingWake = s?.pendingWakeBrightness ?? _pendingWake;
    if (s != null && s.phase != EbPhase.connecting) {
      _status = FixtureStatus(
        phase: _status.phase,
        lastKnown: s.confirmed,
        attempt: _status.attempt,
      );
    }
    await _detach();
  }

  Future<void> _detach() async {
    await _viewSub?.cancel();
    await _eventSub?.cancel();
    _viewSub = null;
    _eventSub = null;
    final EbSession? s = _session;
    _session = null;
    await s?.dispose();
  }

  Future<void> dispose() async {
    _expiry?.cancel();
    await _detach();
    // Listeners get the done event; closing has nothing to wait for.
    unawaited(_statuses.close());
    unawaited(_events.close());
    unawaited(_userLook.close());
  }

  void _set(FixtureStatus s) {
    final FixtureStatus next = s
        ._withOffline(_offlineBrightness)
        ._withPick(_pick);
    // Nothing new: no emit (and no rebuilds or saves behind it).
    if (next == _status) return;
    _status = next;
    if (!_statuses.isClosed) _statuses.add(_status);
  }

  // ---- intents -----------------------------------------------------------------
  // While ready they go straight to the session. While reconnecting the newest
  // change per setting is kept for [offlineWindow] and replayed on connect.

  // A link that just dropped counts as reconnecting: the manager has not
  // moved the phase on yet, but changes made now must not be lost.
  bool get _reconnecting =>
      _status.phase == LinkPhase.waiting ||
      _status.phase == LinkPhase.connecting ||
      _status.phase == LinkPhase.handshaking ||
      _status.phase == LinkPhase.ready;

  bool get _live {
    final EbSession? s = _session;
    return s != null &&
        s.phase != EbPhase.closed &&
        _status.phase == LinkPhase.ready;
  }

  Future<EbResult> _intent(
    String key,
    Future<EbResult> Function(EbSession s) action, {
    Duration keep = offlineWindow,
  }) {
    final EbSession? s = _session;
    if (_live) return action(s!);
    if (_reconnecting) {
      _offline[key] = (
        _scheduler.now,
        keep,
        (EbSession x) => unawaited(action(x)),
      );
      _armExpiry();
    }
    return Future<EbResult>.value(EbResult.disconnected);
  }

  void _armExpiry() {
    _expiry?.cancel();
    _expiry = null;
    if (_offline.isEmpty) return;
    final Duration now = _scheduler.now;
    Duration next = _offline.values
        .map(
          ((Duration, Duration, void Function(EbSession)) e) =>
              e.$1 + e.$2 - now,
        )
        .reduce((Duration a, Duration b) => a < b ? a : b);
    if (next.isNegative) next = Duration.zero;
    _expiry = _scheduler.after(next, _expire);
  }

  /// Drops the changes whose window ran out; a dropped brightness stops
  /// being shown, so the control glides back to the light's value.
  void _expire() {
    _expiry = null;
    final Duration now = _scheduler.now;
    final List<String> expired = <String>[
      for (final MapEntry<
            String,
            (Duration, Duration, void Function(EbSession))
          >
          e
          in _offline.entries)
        if (now - e.value.$1 >= e.value.$2) e.key,
    ];
    if (expired.isNotEmpty) {
      expired.forEach(_offline.remove);
      if (expired.contains(EbKeys.brightness)) {
        _offlineBrightness = null;
        _set(_status);
      }
      if (!_events.isClosed) _events.add(const EbOfflineChangesExpired());
    }
    _armExpiry();
  }

  void _replayOffline(EbSession s) {
    final Duration now = _scheduler.now;
    final List<(Duration, Duration, void Function(EbSession))> fresh =
        _offline.values
            .where(
              ((Duration, Duration, void Function(EbSession)) e) =>
                  now - e.$1 < e.$2,
            )
            .toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
    _offline.clear();
    _expiry?.cancel();
    _expiry = null;
    for (final (Duration, Duration, void Function(EbSession)) e in fresh) {
      e.$3(s);
    }
  }

  /// Result for a colour meant for another layout (e.g. an offline change
  /// replayed after the light was reflashed as another fixture type).
  static const EbResult wrongLayout = EbResult(
    EbOutcome.failed,
    code: 'LAYOUT_CHANGED',
  );

  /// [intent]: what the user picked (the colour editor), shown exactly
  /// until the light reports a colour of its own.
  void setColor(
    ChannelColor c, {
    bool live = false,
    ColourIntent? intent,
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.color);
    unawaited(
      _intent(EbKeys.color, (EbSession s) {
        if (c.layout != s.layout) {
          return Future<EbResult>.value(wrongLayout);
        }
        final int? seq = s.setColor(c, live: live);
        if (seq != null) {
          _pick = intent == null ? null : ColourPick(seq, intent);
        }
        return Future<EbResult>.value(EbResult.ok);
      }),
    );
  }

  /// Colour and brightness in one frame (see [EbSession.setLook]).
  /// [keepOffline]: how long the change waits for a dropped link.
  void setLook({
    ChannelColor? color,
    int? brightness,
    bool live = false,
    Duration keepOffline = offlineWindow,
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, color != null ? EbKeys.color : EbKeys.brightness);
    unawaited(
      _intent(EbKeys.color, (EbSession s) {
        if (color != null && color.layout != s.layout) {
          return Future<EbResult>.value(wrongLayout);
        }
        s.setLook(color: color, brightness: brightness, live: live);
        return Future<EbResult>.value(EbResult.ok);
      }, keep: keepOffline),
    );
  }

  /// Not connected, the change is kept and shown for [offlineWindow], and
  /// sent if the light is back in time (a release at 0 then turns it off).
  /// Otherwise the control glides back to the light's value.
  void setBrightness(
    int b, {
    bool live = false,
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.brightness);
    final bool offline = !_live && _reconnecting;
    unawaited(
      _intent(EbKeys.brightness, (EbSession s) {
        s.setBrightness(b, live: live);
        return Future<EbResult>.value(EbResult.ok);
      }),
    );
    if (offline) {
      _offlineBrightness = b;
      _pendingWake = null;
      _set(_status);
    }
  }

  void beginGesture(String key) => _session?.beginGesture(key);
  void endGesture(String key) => _session?.endGesture(key);

  Future<EbResult> setPower({
    required bool on,
    Duration keepOffline = offlineWindow,
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.power);
    return _intent(
      EbKeys.power,
      (EbSession s) => s.setPower(on: on),
      keep: keepOffline,
    );
  }

  Future<EbResult> setMode(
    int mode, {
    Duration keepOffline = offlineWindow,
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.mode);
    return _intent(
      EbKeys.mode,
      (EbSession s) => s.setMode(mode),
      keep: keepOffline,
    );
  }

  Future<EbResult> setSpeed(
    int mode,
    int v, {
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.speed(mode));
    return _intent(EbKeys.speed(mode), (EbSession s) => s.setSpeed(mode, v));
  }

  Future<EbResult> setFrequency(
    int mode,
    int v, {
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.frequency(mode));
    return _intent(
      EbKeys.frequency(mode),
      (EbSession s) => s.setFrequency(mode, v),
    );
  }

  Future<EbResult> setColorMode(
    EbColorModeKind k,
    int v, {
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.colorMode(k));
    return _intent(EbKeys.colorMode(k), (EbSession s) => s.setColorMode(k, v));
  }

  Future<EbResult> setPoliceColor(
    EbPoliceSlot slot,
    ChannelColor c, {
    CommandOrigin origin = CommandOrigin.user,
  }) {
    _byUser(origin, EbKeys.police(slot));
    return _intent(
      EbKeys.police(slot),
      (EbSession s) => c.layout != s.layout
          ? Future<EbResult>.value(wrongLayout)
          : s.setPoliceColor(slot, c),
    );
  }

  Future<EbResult> setSound({required bool on}) =>
      _intent(EbKeys.sound, (EbSession s) => s.setSound(on: on));

  /// Timer, presets and reset need the light now (no offline replay).
  Future<EbResult> setTimer(int seconds) =>
      _session?.setTimer(seconds) ??
      Future<EbResult>.value(EbResult.disconnected);

  static const EbPresetResult _noPreset = EbPresetResult(EbResult.disconnected);

  /// Saves the current look in [slot]; the result carries the saved scene.
  Future<EbPresetResult> presetSave(int slot) =>
      _session?.presetSave(slot) ?? Future<EbPresetResult>.value(_noPreset);

  /// Loads [slot]; the result carries the complete loaded scene.
  Future<EbPresetResult> presetLoad(
    int slot, {
    CommandOrigin origin = CommandOrigin.user,
  }) {
    final EbSession? s = _session;
    if (s == null) return Future<EbPresetResult>.value(_noPreset);
    _byUser(origin, 'preset');
    return s.presetLoad(slot);
  }

  Future<EbResult> presetDelete(int slot) =>
      _session?.presetDelete(slot) ??
      Future<EbResult>.value(EbResult.disconnected);

  Future<EbResult> factoryReset() =>
      _session?.factoryReset() ?? Future<EbResult>.value(EbResult.disconnected);
}
