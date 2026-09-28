import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import '../core/ble/ble_central.dart';
import '../core/ble/ble_link.dart';
import '../core/model/fixture.dart';
import '../core/protocol/eb/eb_constants.dart';
import '../core/util/scheduler.dart';
import '../drivers/electrobright/eb_session.dart';
import '../drivers/electrobright/eb_types.dart';
import 'discovery.dart';
import 'fixture_session.dart';

/// Why a light should be connected, strongest first. [update]: a wireless
/// firmware update (never evicted). [setup]: a screen setting the light up
/// (developer tools), which also keeps a light in setup-needed mode
/// connected.
enum WantReason { update, setup, screen, action, group, scene, favourite }

/// A registered want; release it when no longer needed.
final class Want {
  Want._(this._owner, this.fixtureId, this.reason);
  final ConnectionManager _owner;
  final String fixtureId;
  final WantReason reason;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._releaseWant(this);
  }
}

final class ConnectionPolicy {
  const ConnectionPolicy({
    required this.isAndroid,
    this.connectTimeout = const Duration(seconds: 10),
    this.idleGrace = const Duration(seconds: 60),
    this.backgroundGrace = const Duration(seconds: 20),
    this.advertFresh = const Duration(seconds: 10),
    this.backoff = const <Duration>[
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    this.unavailableAfter = 3,
    this.stayConnectedInBackground = false,
    this.sessionOptions,
    this._maxConnections,
  });

  final bool isAndroid;
  final Duration connectTimeout;

  /// An unwanted connected light is released after this (foreground).
  final Duration idleGrace;

  /// After going to the background, everything disconnects after this so
  /// other phones can use the lights (firmware allows one phone at a time).
  final Duration backgroundGrace;

  /// Android only connects to lights seen advertising this recently (except
  /// on a direct user action).
  final Duration advertFresh;
  final List<Duration> backoff;

  /// Failed attempts before the UI says "unavailable" (retries continue).
  final int unavailableAfter;
  final bool stayConnectedInBackground;
  final EbSessionOptions? sessionOptions;

  /// Links open at once ([maxConnections] overrides the platform's).
  int get maxConnections => _maxConnections ?? (isAndroid ? 5 : 8);
  final int? _maxConnections;
  int get parallelConnects => isAndroid ? 1 : 2;
}

/// Starts and stops the background task that keeps iOS alive during the
/// background grace period (no-op elsewhere).
abstract interface class BackgroundTasks {
  Future<int> begin(String name);
  Future<void> end(int id);
}

final class NoBackgroundTasks implements BackgroundTasks {
  const NoBackgroundTasks();
  @override
  Future<int> begin(String name) async => -1;
  @override
  Future<void> end(int id) async {}
}

/// Decides which lights are connected: wants, a connection budget, one (or
/// two) connects at a time, backoff with jitter, GATT-133 recovery, reconnect
/// as soon as a wanted light advertises, and the background grace period.
///
/// A light being updated ([WantReason.update]) is exempt from the background
/// release: it keeps (and regains) its link, and the background task stays
/// alive until the update ends. When the OS ends that task anyway, every
/// link goes and [suspended] is true until the app is back in the
/// foreground (the update pauses meanwhile).
final class ConnectionManager {
  ConnectionManager({
    required this._central,
    required this._discovery,
    required this._scheduler,
    required this.policy,
    BackgroundTasks backgroundTasks = const NoBackgroundTasks(),
    Random? random,
  }) : _background = backgroundTasks,
       _random = random ?? Random() {
    _adapterSub = _central.adapterState.listen(_onAdapter);
    _advertSub = _discovery.updates.listen(_onSeen);
  }

  final BleCentral _central;
  final Discovery _discovery;
  final Scheduler _scheduler;
  final BackgroundTasks _background;
  final Random _random;
  final ConnectionPolicy policy;

  late final StreamSubscription<BleAdapterState> _adapterSub;
  late final StreamSubscription<SeenDevice> _advertSub;
  BleAdapterState _adapter = BleAdapterState.unknown;
  final Map<String, _Slot> _slots = <String, _Slot>{};

  /// Device id -> the teardown of a light that was unregistered while it
  /// was connected or connecting. A new connect to the same device waits
  /// for it, so the old link can never close the new one.
  final Map<String, Future<void>> _closing = <String, Future<void>>{};
  bool _inBackground = false;
  Cancelable? _backgroundTimer;

  /// The background grace period is over: only an update keeps its link.
  bool _graceOver = false;
  bool _suspended = false;
  final StreamController<bool> _suspensions = StreamController<bool>.broadcast(
    sync: true,
  );
  int? _backgroundTask;
  ScanLease? _reconnectLease;
  bool _disposed = false;

  Iterable<FixtureSession> get sessions =>
      _slots.values.map((_Slot s) => s.session);
  FixtureSession? session(String fixtureId) => _slots[fixtureId]?.session;

  /// Whether [deviceId] is a registered (saved) light.
  bool manages(String deviceId) =>
      _slots.values.any((_Slot s) => s.session.fixture.deviceId == deviceId);

  void register(Fixture f) {
    final _Slot? s = _slots[f.id];
    if (s != null) {
      s.session.fixture = f;
      return;
    }
    _slots[f.id] = _Slot(FixtureSession(f, scheduler: _scheduler));
  }

  /// Forgets a light. Its slot goes at once; the link (or a connect still
  /// in progress) is closed before the device is connected again.
  Future<void> unregister(String fixtureId) async {
    final _Slot? s = _slots.remove(fixtureId);
    if (s == null) return;
    s.retry?.cancel();
    s.idleTimer?.cancel();
    s.cancelConnect();
    final String deviceId = s.session.fixture.deviceId;
    final Future<void> closed = _close(s);
    _closing[deviceId] = closed;
    try {
      await closed;
    } finally {
      _closing.removeWhere((_, Future<void> f) => identical(f, closed));
      _evaluate();
      await s.session.dispose();
    }
  }

  /// Closes [s]'s link: what a new connect to the same light waits for.
  /// Never throws, so what follows it (the session's disposal) always runs.
  static Future<void> _close(_Slot s) async {
    // A connect in progress disconnects by itself once its slot is gone.
    try {
      await s.connectDone;
    } on Object catch (e, st) {
      _logCleanupError('connect', e, st);
    }
    await _disconnect(s.link);
  }

  /// Closes [link]. A plugin error is logged (debug builds) and swallowed:
  /// the cleanup after a disconnect must always run, and its callers
  /// (screens being torn down, dispose) have nothing to do with it.
  static Future<void> _disconnect(BleLink? link) async {
    if (link == null) return;
    try {
      await link.disconnect();
    } on Object catch (e, st) {
      _logCleanupError('disconnect', e, st);
    }
  }

  static void _logCleanupError(String what, Object e, StackTrace st) {
    assert(() {
      developer.log(
        '$what failed during cleanup',
        name: 'ConnectionManager',
        error: e,
        stackTrace: st,
      );
      return true;
    }());
  }

  /// Registers a reason to keep [fixtureId] connected.
  Want want(String fixtureId, WantReason reason) {
    final _Slot slot = _slots[fixtureId] ?? (throw ArgumentError(fixtureId));
    final Want w = Want._(this, fixtureId, reason);
    slot.wants.add(w);
    slot.lastUsed = _scheduler.now;
    slot.idleTimer?.cancel();
    slot.idleTimer = null;
    // A direct user action skips the remaining backoff.
    if (reason == WantReason.action ||
        reason == WantReason.screen ||
        reason == WantReason.setup ||
        reason == WantReason.update) {
      slot.retry?.cancel();
      slot.retry = null;
      slot.userAt = _scheduler.now;
    }
    _evaluate();
    return w;
  }

  void _releaseWant(Want w) {
    final _Slot? slot = _slots[w.fixtureId];
    if (slot == null) return;
    slot.wants.remove(w);
    _evaluate();
  }

  /// Drops the link now; it reconnects at once if still wanted (diagnostics,
  /// "unresponsive" recovery).
  Future<void> reconnect(String fixtureId) async {
    final _Slot? s = _slots[fixtureId];
    await _disconnect(s?.link);
  }

  /// Tries a light again that was given up on (e.g. "Firmware update needed"
  /// after the user flashed it, or "unavailable" after they powered it on).
  void retry(String fixtureId) {
    final _Slot? s = _slots[fixtureId];
    if (s == null || s.link != null || s.connecting) return;
    s.retry?.cancel();
    s.retry = null;
    s.attempt = 0;
    s.session.setPhase(s.wants.isEmpty ? LinkPhase.idle : LinkPhase.waiting);
    _evaluate();
  }

  // ---- lifecycle -------------------------------------------------------------------

  /// The background task ended while the app was in the background: nothing
  /// is connected until it is back in the foreground.
  bool get suspended => _suspended;

  /// [suspended]'s changes (delivered synchronously, before the links go).
  Stream<bool> get suspensions => _suspensions.stream;

  Future<void> onBackground() async {
    if (_inBackground) return;
    _inBackground = true;
    // Nothing reconnects in the background: drop the reconnect scan now.
    _evaluate();
    if (policy.stayConnectedInBackground) return;
    _backgroundTask = await _background.begin('eb-release');
    _backgroundTimer = _scheduler.after(policy.backgroundGrace, () {
      _graceOver = true;
      unawaited(_releaseAll());
    });
  }

  Future<void> onForeground() async {
    if (!_inBackground) return;
    _inBackground = false;
    _graceOver = false;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    if (_suspended) {
      _suspended = false;
      _suspensions.add(false);
    }
    await _endBackgroundTask();
    for (final _Slot s in _slots.values) {
      final EbSession? es = s.session.session;
      if (es != null && s.session.status.isReady) unawaited(es.onResume());
    }
    _evaluate();
  }

  /// Called by the platform when the background task is about to expire:
  /// everything goes, an update too (it pauses until the app is back).
  Future<void> onBackgroundExpiring() async {
    if (_inBackground && !_suspended) {
      _suspended = true;
      _suspensions.add(true);
    }
    await _releaseAll(evenUpdates: true);
  }

  /// Releases every light, except one being updated unless [evenUpdates];
  /// the background task ends once nothing is updating.
  Future<void> _releaseAll({bool evenUpdates = false}) async {
    _backgroundTimer?.cancel();
    for (final _Slot s in _slots.values) {
      if (!evenUpdates && s.updating) continue;
      s.retry?.cancel();
      s.retry = null;
      // A waiting connect would take the light the moment it appears.
      s.cancelConnect();
      await _disconnect(s.link);
    }
    if (evenUpdates || !_slots.values.any((_Slot s) => s.updating)) {
      await _endBackgroundTask();
    }
  }

  Future<void> _endBackgroundTask() async {
    final int? id = _backgroundTask;
    _backgroundTask = null;
    if (id != null && id >= 0) await _background.end(id);
  }

  /// Stops every timer and decision at once (synchronous part of dispose).
  void halt() {
    _disposed = true;
    _backgroundTimer?.cancel();
    for (final _Slot s in _slots.values) {
      s.retry?.cancel();
      s.retry = null;
      s.idleTimer?.cancel();
      s.idleTimer = null;
      // Its timers (command timeouts, timer watch) stop now too; closing is
      // idempotent, so the full dispose later finds nothing left to do.
      final EbSession? live = s.session.session;
      if (live != null) unawaited(live.dispose());
    }
  }

  Future<void> dispose() async {
    halt();
    unawaited(_suspensions.close());
    _reconnectLease?.release();
    await _adapterSub.cancel();
    await _advertSub.cancel();
    for (final _Slot s in _slots.values) {
      s.retry?.cancel();
      s.idleTimer?.cancel();
      await _disconnect(s.link);
      await s.session.dispose();
    }
    _slots.clear();
  }

  // ---- decisions ---------------------------------------------------------------------

  void _onAdapter(BleAdapterState s) {
    _adapter = s;
    if (s != BleAdapterState.ready) {
      for (final _Slot slot in _slots.values) {
        if (slot.wants.isNotEmpty) {
          slot.session.setPhase(LinkPhase.bluetoothOff);
        }
      }
    }
    _evaluate();
  }

  void _onSeen(SeenDevice d) {
    for (final _Slot s in _slots.values) {
      if (s.session.fixture.deviceId != d.id) continue;
      // Advertising means it is free right now: skip the remaining backoff.
      // Not if it was advertising when it last failed: the advert is no news
      // and retrying at once would only fail again (a retry per advert).
      if (s.wants.isNotEmpty && s.link == null && !s.connecting) {
        if (s.retry != null && s.retryInSight) continue;
        s.retry?.cancel();
        s.retry = null;
        _evaluate();
      }
    }
  }

  void _evaluate() {
    if (_disposed) return;
    _updateReconnectLease();
    if (_adapter != BleAdapterState.ready) {
      // A light wanted while Bluetooth is already unusable says so (not
      // before the first report: that would flash at start-up).
      if (_adapter != BleAdapterState.unknown) {
        for (final _Slot s in _slots.values) {
          if (s.wants.isNotEmpty && s.link == null && !s.connecting) {
            s.session.setPhase(LinkPhase.bluetoothOff);
          }
        }
      }
      return;
    }
    if (_inBackground) return _evaluateInBackground();

    // Release lights nobody wants (after a grace period).
    for (final _Slot s in _slots.values) {
      if (s.wants.isEmpty && s.link != null && s.idleTimer == null) {
        s.idleTimer = _scheduler.after(policy.idleGrace, () {
          s.idleTimer = null;
          if (s.wants.isEmpty) unawaited(_disconnect(s.link));
        });
      }
      if (s.wants.isEmpty && s.link == null && !s.connecting) {
        s.session.setPhase(LinkPhase.idle);
      }
      // A light kept in setup-needed mode goes as soon as nothing sets it up.
      if (s.link != null && s.session.inSetup && !s.wantsSetup) {
        unawaited(_disconnect(s.link));
      }
      // A waiting (open-ended) connect nobody wants any more is abandoned.
      if (s.wants.isEmpty) s.cancelConnect();
    }

    final List<_Slot> candidates =
        _slots.values
            .where(
              (_Slot s) =>
                  s.wants.isNotEmpty &&
                  s.link == null &&
                  !s.connecting &&
                  s.retry == null &&
                  (s.session.status.phase != LinkPhase.incompatible ||
                      (s.wantsSetup &&
                          s.session.status.incompatibility ==
                              EbIncompatibility.setupNeeded)),
            )
            .toList()
          ..sort((_Slot a, _Slot b) {
            final int p = a.priority.index.compareTo(b.priority.index);
            return p != 0 ? p : b.lastUsed.compareTo(a.lastUsed);
          });

    for (final _Slot s in candidates) {
      final String deviceId = s.session.fixture.deviceId;
      if (_busyConnects >= policy.parallelConnects &&
          !(_openEnded(s) && !_inSight(deviceId))) {
        continue;
      }
      final bool userJustAsked =
          s.userAt != null &&
          _scheduler.now - s.userAt! < const Duration(seconds: 3);
      if (policy.isAndroid &&
          !userJustAsked &&
          !_discovery.seenRecently(deviceId, policy.advertFresh)) {
        // Android: connecting to a light that is not advertising hangs the
        // stack; wait for its advert (reconnect scan is running).
        if (s.session.status.phase != LinkPhase.unavailable) {
          s.session.setPhase(LinkPhase.waiting);
        }
        continue;
      }
      if (_connectedCount >= policy.maxConnections && !_evictOne(s)) {
        s.session.setPhase(LinkPhase.waiting, detail: 'deferred');
        continue;
      }
      s.connectDone = _connect(s);
    }
  }

  /// In the background only an update keeps (or regains) its link; after
  /// the grace period a light whose update ended goes at once.
  void _evaluateInBackground() {
    for (final _Slot s in _slots.values) {
      if (s.updating) continue;
      if (_graceOver) {
        s.cancelConnect();
        if (s.link != null) unawaited(_disconnect(s.link));
      }
    }
    if (_graceOver && !_slots.values.any((_Slot s) => s.updating)) {
      unawaited(_endBackgroundTask());
    }
    if (_suspended) return;
    for (final _Slot s in _slots.values) {
      if (s.updating &&
          s.link == null &&
          !s.connecting &&
          s.retry == null &&
          s.session.status.phase != LinkPhase.incompatible &&
          // Android: only to a light seen advertising (see _evaluate).
          (!policy.isAndroid ||
              _discovery.seenRecently(
                s.session.fixture.deviceId,
                policy.advertFresh,
              ))) {
        s.connectDone = _connect(s);
      }
    }
  }

  int get _connectedCount =>
      _slots.values.where((_Slot s) => s.link != null).length;

  /// iOS favourites wait for the light to appear (open-ended connect).
  bool _openEnded(_Slot s) =>
      !policy.isAndroid && s.priority == WantReason.favourite;

  /// Connects in progress that take a slot: an open-ended connect to a light
  /// that isn't advertising is only waiting for it (the system does), so it
  /// never keeps a light the user opens from connecting.
  int get _busyConnects => _slots.values
      .where(
        (_Slot s) =>
            s.connecting &&
            !(s.openEnded && !_inSight(s.session.fixture.deviceId)),
      )
      .length;

  /// Disconnects the least-recently-used idle light to make room for [forS].
  bool _evictOne(_Slot forS) {
    final List<_Slot> idle =
        _slots.values
            .where(
              (_Slot s) =>
                  s.link != null &&
                  s.wants.every(
                    (Want w) => w.reason.index > forS.priority.index,
                  ) &&
                  (s.session.session?.isIdle ?? true),
            )
            .toList()
          ..sort((_Slot a, _Slot b) => a.lastUsed.compareTo(b.lastUsed));
    if (idle.isEmpty) return false;
    unawaited(_disconnect(idle.first.link));
    return false; // room appears once the link has closed
  }

  void _updateReconnectLease() {
    final bool need =
        !_inBackground &&
        _slots.values.any((_Slot s) => s.wants.isNotEmpty && s.link == null);
    if (need && _reconnectLease == null) {
      _reconnectLease = _discovery.acquire(ScanNeed.reconnect);
    } else if (!need && _reconnectLease != null) {
      _reconnectLease!.release();
      _reconnectLease = null;
    }
  }

  Future<void> _connect(_Slot s) async {
    s.connecting = true;
    s.session.setPhase(LinkPhase.connecting, attempt: s.attempt);
    final Fixture f = s.session.fixture;
    BleLink? link;
    final bool openEnded = s.openEnded = _openEnded(s);
    final Completer<void>? cancel = s.cancel = openEnded
        ? Completer<void>()
        : null;
    // An open-ended iOS connect waits quietly; after the normal timeout the
    // UI still says "unavailable" so the user is never left guessing.
    final Cancelable? honest = openEnded
        ? _scheduler.after(policy.connectTimeout, () {
            if (s.connecting) s.session.setPhase(LinkPhase.unavailable);
          })
        : null;
    try {
      // The previous link to this light is still being torn down.
      final Future<void>? closing = _closing[f.deviceId];
      if (closing != null) await closing;
      if (!identical(_slots[f.id], s) || s.wants.isEmpty) return;
      link = await _central.connect(
        f.deviceId,
        services: <String, List<String>>{
          Eb.serviceUuid: <String>[Eb.rxUuid, Eb.txUuid],
        },
        // iOS favourites wait for the light to appear (open-ended connect).
        timeout: openEnded ? null : policy.connectTimeout,
        cancel: cancel?.future,
      );
      if (_disposed ||
          s.wants.isEmpty ||
          (_inBackground && (!s.updating || _suspended)) ||
          !identical(_slots[f.id], s)) {
        await _disconnect(link);
        return;
      }
      s.link = link;
      unawaited(link.closed.then((LinkLossReason r) => _onClosed(s, link!, r)));
      await s.session.attach(
        link,
        options: policy.sessionOptions,
        // A light without a fixture type gets only the commands it accepts.
        setupFirst: _discovery.devices.any(
          (SeenDevice d) => d.id == f.deviceId && d.name == Eb.setupName,
        ),
        // Being set up: such a light keeps the link for PROBE and SET_TYPE.
        keepSetup: s.wantsSetup,
      );
      s.attempt = 0;
      s.gatt133 = 0;
      s.lastUsed = _scheduler.now;
      _eventsFor(s);
    } on EbIncompatible catch (e) {
      // Detach first so the closed link is not taken for a drop (which would
      // reconnect forever): an incompatible light stays incompatible until
      // the user retries it.
      s.link = null;
      await s.session.linkClosed();
      await _disconnect(link);
      s.session.setPhase(
        LinkPhase.incompatible,
        incompatibility: e.kind,
        detail: e.reason,
      );
    } on ConnectException catch (e) {
      if (cancel?.isCompleted ?? false) {
        // Abandoned (unwanted, or the app went to background): not a
        // failure; it is tried again when wanted in the foreground.
        s.session.setPhase(
          s.wants.isEmpty ? LinkPhase.idle : LinkPhase.waiting,
        );
      } else if (_adapter != BleAdapterState.ready) {
        // Bluetooth went off during the attempt: not the light's failure,
        // and nothing to retry until it is back.
        s.session.setPhase(LinkPhase.bluetoothOff);
      } else if (e.gattStatus == 133) {
        s.gatt133++;
        if (s.gatt133 >= 2) await _central.clearCache(f.deviceId);
        _retryIn(
          s,
          Duration(milliseconds: 600 * s.gatt133),
          inSight: _inSight(f.deviceId),
        );
      } else {
        _failed(s);
      }
    } on Object {
      await _disconnect(link);
      if (_adapter != BleAdapterState.ready) {
        s.session.setPhase(LinkPhase.bluetoothOff);
      } else {
        _failed(s);
      }
    } finally {
      honest?.cancel();
      s.connecting = false;
      s.openEnded = false;
      s.cancel = null;
      _evaluate();
    }
  }

  void _eventsFor(_Slot s) {
    unawaited(s.eventSub?.cancel());
    s.eventSub = s.session.events.listen((EbEvent e) {
      // The light stopped answering: drop and reconnect.
      if (e is EbUnresponsive) unawaited(_disconnect(s.link));
    });
  }

  void _failed(_Slot s) {
    s.attempt++;
    if (s.attempt >= policy.unavailableAfter) {
      s.session.setPhase(LinkPhase.unavailable, attempt: s.attempt);
    } else {
      s.session.setPhase(LinkPhase.waiting, attempt: s.attempt);
    }
    final Duration base =
        policy.backoff[min(s.attempt - 1, policy.backoff.length - 1)];
    final double jitter = 0.8 + _random.nextDouble() * 0.4;
    _retryIn(
      s,
      Duration(microseconds: (base.inMicroseconds * jitter).round()),
      inSight: _inSight(s.session.fixture.deviceId),
    );
  }

  /// Advertising just now (within a couple of advert intervals).
  bool _inSight(String deviceId) =>
      _discovery.seenRecently(deviceId, const Duration(seconds: 2));

  /// [inSight]: the light was advertising when the attempt failed.
  void _retryIn(_Slot s, Duration d, {bool inSight = false}) {
    s.retryInSight = inSight;
    s.retry?.cancel();
    s.retry = _scheduler.after(d, () {
      s.retry = null;
      _evaluate();
    });
  }

  Future<void> _onClosed(_Slot s, BleLink link, LinkLossReason reason) async {
    if (!identical(s.link, link)) return;
    s.link = null;
    s.idleTimer?.cancel();
    s.idleTimer = null;
    await s.eventSub?.cancel();
    s.eventSub = null;
    await s.session.linkClosed();
    if (_disposed) return;
    final bool setupNeeded =
        s.session.status.incompatibility == EbIncompatibility.setupNeeded;
    // The plugin may report an adapter switch-off as an ordinary loss.
    if (reason == LinkLossReason.adapterOff ||
        _adapter != BleAdapterState.ready) {
      s.session.setPhase(LinkPhase.bluetoothOff);
    } else if (setupNeeded && !s.wantsSetup) {
      // Released after setting up: it stays what it was until retried.
      s.session.setPhase(LinkPhase.incompatible);
    } else if (s.wants.isNotEmpty &&
        (!_inBackground || (s.updating && !_suspended))) {
      s.session.setPhase(LinkPhase.waiting);
      if (reason != LinkLossReason.requested) _retryIn(s, policy.backoff.first);
    } else {
      s.session.setPhase(LinkPhase.idle);
    }
    _evaluate();
  }
}

final class _Slot {
  _Slot(this.session);
  final FixtureSession session;
  final List<Want> wants = <Want>[];
  BleLink? link;
  bool connecting = false;
  int attempt = 0;
  int gatt133 = 0;
  Duration lastUsed = Duration.zero;
  Duration? userAt;
  Cancelable? retry;

  /// The pending [retry] follows a failure while the light was advertising.
  bool retryInSight = false;

  /// The connect in progress is open-ended (it waits for the light).
  bool openEnded = false;

  /// Completing it abandons the open-ended connect in progress.
  Completer<void>? cancel;

  /// The latest connect attempt (done once it succeeded or failed).
  Future<void>? connectDone;

  void cancelConnect() {
    final Completer<void>? c = cancel;
    if (c != null && !c.isCompleted) c.complete();
  }

  Cancelable? idleTimer;
  // Cancelled in _onClosed / on re-attach.
  // ignore: cancel_subscriptions
  StreamSubscription<EbEvent>? eventSub;

  /// The light is being updated ([WantReason.update]).
  bool get updating => wants.any((Want w) => w.reason == WantReason.update);

  /// A screen is setting the light up ([WantReason.setup]).
  bool get wantsSetup => wants.any((Want w) => w.reason == WantReason.setup);

  WantReason get priority => wants.isEmpty
      ? WantReason.favourite
      : wants
            .map((Want w) => w.reason)
            .reduce((WantReason a, WantReason b) => a.index <= b.index ? a : b);
}
