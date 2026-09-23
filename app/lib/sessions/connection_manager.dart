import 'dart:async';
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

/// Why a light should be connected, strongest first.
enum WantReason { screen, action, group, scene, favourite }

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

  int get maxConnections => isAndroid ? 5 : 8;
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
  int _connecting = 0;
  bool _inBackground = false;
  Cancelable? _backgroundTimer;
  int? _backgroundTask;
  ScanLease? _reconnectLease;
  bool _disposed = false;

  Iterable<FixtureSession> get sessions =>
      _slots.values.map((_Slot s) => s.session);
  FixtureSession? session(String fixtureId) => _slots[fixtureId]?.session;

  void register(Fixture f) {
    final _Slot? s = _slots[f.id];
    if (s != null) {
      s.session.fixture = f;
      return;
    }
    _slots[f.id] = _Slot(FixtureSession(f, scheduler: _scheduler));
  }

  Future<void> unregister(String fixtureId) async {
    final _Slot? s = _slots.remove(fixtureId);
    if (s == null) return;
    s.retry?.cancel();
    s.idleTimer?.cancel();
    await s.link?.disconnect();
    await s.session.dispose();
    _evaluate();
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
    if (reason == WantReason.action || reason == WantReason.screen) {
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
    await s?.link?.disconnect();
  }

  // ---- lifecycle -------------------------------------------------------------------

  Future<void> onBackground() async {
    if (_inBackground) return;
    _inBackground = true;
    if (policy.stayConnectedInBackground) return;
    _backgroundTask = await _background.begin('eb-release');
    _backgroundTimer = _scheduler.after(policy.backgroundGrace, () {
      unawaited(_releaseAll());
    });
  }

  Future<void> onForeground() async {
    if (!_inBackground) return;
    _inBackground = false;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    await _endBackgroundTask();
    for (final _Slot s in _slots.values) {
      final EbSession? es = s.session.session;
      if (es != null && s.session.status.isReady) unawaited(es.onResume());
    }
    _evaluate();
  }

  /// Called by the platform when the background task is about to expire.
  Future<void> onBackgroundExpiring() => _releaseAll();

  Future<void> _releaseAll() async {
    _backgroundTimer?.cancel();
    for (final _Slot s in _slots.values) {
      s.retry?.cancel();
      s.retry = null;
      await s.link?.disconnect();
    }
    await _endBackgroundTask();
  }

  Future<void> _endBackgroundTask() async {
    final int? id = _backgroundTask;
    _backgroundTask = null;
    if (id != null && id >= 0) await _background.end(id);
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectLease?.release();
    await _adapterSub.cancel();
    await _advertSub.cancel();
    for (final _Slot s in _slots.values) {
      s.retry?.cancel();
      s.idleTimer?.cancel();
      await s.link?.disconnect();
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
      if (s.wants.isNotEmpty && s.link == null && !s.connecting) {
        s.retry?.cancel();
        s.retry = null;
        _evaluate();
      }
    }
  }

  void _evaluate() {
    if (_disposed) return;
    _updateReconnectLease();
    if (_adapter != BleAdapterState.ready || _inBackground) return;

    // Release lights nobody wants (after a grace period).
    for (final _Slot s in _slots.values) {
      if (s.wants.isEmpty && s.link != null && s.idleTimer == null) {
        s.idleTimer = _scheduler.after(policy.idleGrace, () {
          s.idleTimer = null;
          if (s.wants.isEmpty) unawaited(s.link?.disconnect());
        });
      }
      if (s.wants.isEmpty && s.link == null && !s.connecting) {
        s.session.setPhase(LinkPhase.idle);
      }
    }

    final List<_Slot> candidates =
        _slots.values
            .where(
              (_Slot s) =>
                  s.wants.isNotEmpty &&
                  s.link == null &&
                  !s.connecting &&
                  s.retry == null &&
                  s.session.status.phase != LinkPhase.incompatible,
            )
            .toList()
          ..sort((_Slot a, _Slot b) {
            final int p = a.priority.index.compareTo(b.priority.index);
            return p != 0 ? p : b.lastUsed.compareTo(a.lastUsed);
          });

    for (final _Slot s in candidates) {
      if (_connecting >= policy.parallelConnects) break;
      final String deviceId = s.session.fixture.deviceId;
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
      unawaited(_connect(s));
    }
  }

  int get _connectedCount =>
      _slots.values.where((_Slot s) => s.link != null).length;

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
    unawaited(idle.first.link!.disconnect());
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
    _connecting++;
    s.session.setPhase(LinkPhase.connecting, attempt: s.attempt);
    final Fixture f = s.session.fixture;
    BleLink? link;
    final bool openEnded =
        !policy.isAndroid && s.priority == WantReason.favourite;
    // An open-ended iOS connect waits quietly; after the normal timeout the
    // UI still says "unavailable" so the user is never left guessing.
    final Cancelable? honest = openEnded
        ? _scheduler.after(policy.connectTimeout, () {
            if (s.connecting) s.session.setPhase(LinkPhase.unavailable);
          })
        : null;
    try {
      link = await _central.connect(
        f.deviceId,
        services: <String, List<String>>{
          Eb.serviceUuid: <String>[Eb.rxUuid, Eb.txUuid],
        },
        // iOS favourites wait for the light to appear (open-ended connect).
        timeout: openEnded ? null : policy.connectTimeout,
      );
      if (_disposed || s.wants.isEmpty || _inBackground) {
        await link.disconnect();
        return;
      }
      s.link = link;
      unawaited(link.closed.then((LinkLossReason r) => _onClosed(s, link!, r)));
      await s.session.attach(link, options: policy.sessionOptions);
      s.attempt = 0;
      s.gatt133 = 0;
      s.lastUsed = _scheduler.now;
      _eventsFor(s);
    } on EbIncompatible catch (e) {
      await link?.disconnect();
      s.session.setPhase(
        LinkPhase.incompatible,
        legacy: e.legacy,
        detail: e.reason,
      );
    } on ConnectException catch (e) {
      if (e.gattStatus == 133) {
        s.gatt133++;
        if (s.gatt133 >= 2) await _central.clearCache(f.deviceId);
        _retryIn(s, Duration(milliseconds: 600 * s.gatt133));
      } else {
        _failed(s);
      }
    } on Object {
      await link?.disconnect();
      _failed(s);
    } finally {
      honest?.cancel();
      s.connecting = false;
      _connecting--;
      _evaluate();
    }
  }

  void _eventsFor(_Slot s) {
    unawaited(s.eventSub?.cancel());
    s.eventSub = s.session.events.listen((EbEvent e) {
      // The light stopped answering: drop and reconnect.
      if (e is EbUnresponsive) unawaited(s.link?.disconnect());
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
    _retryIn(s, Duration(microseconds: (base.inMicroseconds * jitter).round()));
  }

  void _retryIn(_Slot s, Duration d) {
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
    if (reason == LinkLossReason.adapterOff) {
      s.session.setPhase(LinkPhase.bluetoothOff);
    } else if (s.wants.isNotEmpty && !_inBackground) {
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
  Cancelable? idleTimer;
  // Cancelled in _onClosed / on re-attach.
  // ignore: cancel_subscriptions
  StreamSubscription<EbEvent>? eventSub;

  WantReason get priority => wants.isEmpty
      ? WantReason.favourite
      : wants
            .map((Want w) => w.reason)
            .reduce((WantReason a, WantReason b) => a.index <= b.index ? a : b);
}
