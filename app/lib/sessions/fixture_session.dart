import 'dart:async';

import 'package:meta/meta.dart';

import '../core/ble/ble_link.dart';
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
    this.legacyFirmware = false,
    this.detail,
  });

  final LinkPhase phase;

  /// Live session view while connected.
  final EbView? view;

  /// The last confirmed state (shown dimmed while not connected).
  final EbDeviceState? lastKnown;
  final int attempt;
  final bool legacyFirmware;
  final String? detail;

  bool get isReady => phase == LinkPhase.ready && view != null;

  /// What the UI should render: live when connected, else the last known.
  EbDeviceState? get state => view?.state ?? lastKnown;
}

/// One saved light: its (optional) live driver session plus the last-known
/// state and short-lived offline changes. Owned by the ConnectionManager.
final class FixtureSession {
  FixtureSession(this.fixture, {required this._scheduler});

  Fixture fixture;
  final Scheduler _scheduler;

  /// Offline changes older than this are dropped instead of replayed.
  static const Duration offlineWindow = Duration(seconds: 10);

  FixtureStatus _status = const FixtureStatus(phase: LinkPhase.idle);
  final StreamController<FixtureStatus> _statuses =
      StreamController<FixtureStatus>.broadcast();
  final StreamController<EbEvent> _events =
      StreamController<EbEvent>.broadcast();
  EbSession? _session;
  StreamSubscription<EbView>? _viewSub;
  StreamSubscription<EbEvent>? _eventSub;
  final Map<String, (Duration, void Function(EbSession))> _offline =
      <String, (Duration, void Function(EbSession))>{};

  FixtureStatus get status => _status;
  Stream<FixtureStatus> get statuses => _statuses.stream;
  Stream<EbEvent> get events => _events.stream;
  EbSession? get session => _session;

  void setPhase(LinkPhase phase, {int? attempt, bool? legacy, String? detail}) {
    _set(
      FixtureStatus(
        phase: phase,
        view: phase == LinkPhase.ready ? _session?.view : null,
        lastKnown: _status.lastKnown,
        attempt: attempt ?? _status.attempt,
        legacyFirmware: legacy ?? _status.legacyFirmware,
        detail: detail,
      ),
    );
  }

  /// Takes over a fresh link: handshake, then replay recent offline changes.
  /// Throws what [EbSession.start] throws (the caller decides on retries).
  Future<void> attach(BleLink link, {EbSessionOptions? options}) async {
    await _detach();
    final EbSession s = EbSession(
      link: link,
      scheduler: _scheduler,
      options: options ?? const EbSessionOptions(),
      expectedLayout: fixture.layout,
    );
    _session = s;
    setPhase(LinkPhase.handshaking);
    try {
      await s.start();
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
  }

  /// The link ended (the manager already knows).
  Future<void> linkClosed() async {
    final EbSession? s = _session;
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
    await _detach();
    await _statuses.close();
    await _events.close();
  }

  void _set(FixtureStatus s) {
    _status = s;
    if (!_statuses.isClosed) _statuses.add(s);
  }

  // ---- intents -----------------------------------------------------------------
  // While ready they go straight to the session. While reconnecting the newest
  // change per setting is kept for [offlineWindow] and replayed on connect.

  bool get _reconnecting =>
      _status.phase == LinkPhase.waiting ||
      _status.phase == LinkPhase.connecting ||
      _status.phase == LinkPhase.handshaking;

  Future<EbResult> _intent(
    String key,
    Future<EbResult> Function(EbSession s) action,
  ) {
    final EbSession? s = _session;
    if (s != null && _status.phase == LinkPhase.ready) return action(s);
    if (_reconnecting) {
      _offline[key] = (_scheduler.now, (EbSession x) => unawaited(action(x)));
      return Future<EbResult>.value(EbResult.disconnected);
    }
    return Future<EbResult>.value(EbResult.disconnected);
  }

  void _replayOffline(EbSession s) {
    final Duration now = _scheduler.now;
    final List<(Duration, void Function(EbSession))> fresh =
        _offline.values
            .where(
              ((Duration, void Function(EbSession)) e) =>
                  now - e.$1 <= offlineWindow,
            )
            .toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
    _offline.clear();
    for (final (Duration, void Function(EbSession)) e in fresh) {
      e.$2(s);
    }
  }

  /// Result for a colour meant for another layout (e.g. an offline change
  /// replayed after the light was reflashed as another fixture type).
  static const EbResult wrongLayout = EbResult(
    EbOutcome.failed,
    code: 'LAYOUT_CHANGED',
  );

  void setColor(ChannelColor c, {bool live = false}) => unawaited(
    _intent(EbKeys.color, (EbSession s) {
      if (c.layout != s.layout) return Future<EbResult>.value(wrongLayout);
      s.setColor(c, live: live);
      return Future<EbResult>.value(EbResult.ok);
    }),
  );

  /// Colour and brightness in one frame (see [EbSession.setLook]).
  void setLook({ChannelColor? color, int? brightness, bool live = false}) =>
      unawaited(
        _intent(EbKeys.color, (EbSession s) {
          if (color != null && color.layout != s.layout) {
            return Future<EbResult>.value(wrongLayout);
          }
          s.setLook(color: color, brightness: brightness, live: live);
          return Future<EbResult>.value(EbResult.ok);
        }),
      );

  void setBrightness(int b, {bool live = false}) => unawaited(
    _intent(EbKeys.brightness, (EbSession s) {
      s.setBrightness(b, live: live);
      return Future<EbResult>.value(EbResult.ok);
    }),
  );

  void beginGesture(String key) => _session?.beginGesture(key);
  void endGesture(String key) => _session?.endGesture(key);

  Future<EbResult> setPower({required bool on}) =>
      _intent(EbKeys.power, (EbSession s) => s.setPower(on: on));
  Future<EbResult> setMode(int mode) =>
      _intent(EbKeys.mode, (EbSession s) => s.setMode(mode));
  Future<EbResult> setSpeed(int mode, int v) =>
      _intent(EbKeys.speed(mode), (EbSession s) => s.setSpeed(mode, v));
  Future<EbResult> setFrequency(int mode, int v) =>
      _intent(EbKeys.frequency(mode), (EbSession s) => s.setFrequency(mode, v));
  Future<EbResult> setColorMode(EbColorModeKind k, int v) =>
      _intent(EbKeys.colorMode(k), (EbSession s) => s.setColorMode(k, v));
  Future<EbResult> setPoliceColor(EbPoliceSlot slot, ChannelColor c) => _intent(
    EbKeys.police(slot),
    (EbSession s) => c.layout != s.layout
        ? Future<EbResult>.value(wrongLayout)
        : s.setPoliceColor(slot, c),
  );
  Future<EbResult> setSound({required bool on}) =>
      _intent(EbKeys.sound, (EbSession s) => s.setSound(on: on));

  /// Timer, presets and reset need the light now (no offline replay).
  Future<EbResult> setTimer(int seconds) =>
      _session?.setTimer(seconds) ??
      Future<EbResult>.value(EbResult.disconnected);
}
