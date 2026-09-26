import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../core/color/colour_engine.dart';
import '../core/model/channel_color.dart';
import '../core/model/fixture.dart';
import '../core/model/light_capabilities.dart';
import '../core/store/json_store.dart';
import '../core/util/scheduler.dart';
import '../drivers/electrobright/eb_types.dart';
import 'connection_manager.dart';
import 'fixture_registry.dart';
import 'fixture_session.dart';
import 'group_capabilities.dart';

/// One member of the group as the UI lists it.
@immutable
final class GroupMember {
  const GroupMember(
    this.id,
    this.phase, {
    this.limitedOut = false,
    this.following = false,
    this.own = false,
  });
  final String id;
  final LinkPhase phase;

  /// Not connected for the group: the connection budget ran out.
  final bool limitedOut;

  /// Got a group command since it last joined.
  final bool following;

  /// Detached by a change on its own controls: group commands skip it
  /// until it rejoins.
  final bool own;

  @override
  bool operator ==(Object other) =>
      other is GroupMember &&
      other.id == id &&
      other.phase == phase &&
      other.limitedOut == limitedOut &&
      other.following == following &&
      other.own == own;
  @override
  int get hashCode => Object.hash(id, phase, limitedOut, following, own);
  @override
  String toString() =>
      'GroupMember($id, ${phase.name}${limitedOut ? ', limited out' : ''}'
      '${following ? ', following' : ''}${own ? ', own' : ''})';
}

/// Where the group's lights are: each member plus the counts.
@immutable
final class GroupStatus {
  const GroupStatus({
    this.active = false,
    this.members = const <GroupMember>[],
    this.excluded = const <String>[],
    this.capabilities = const GroupCapabilities.none(),
  });
  final bool active;

  /// Every saved light not left out, in Home's order (own ones included).
  final List<GroupMember> members;

  /// Lights left out of the group, in Home's order.
  final List<String> excluded;

  /// The group's colour controls, from the lights it drives.
  final GroupCapabilities capabilities;

  int get total => members.length;
  int get ready => _count((GroupMember m) => m.phase == LinkPhase.ready);
  int get connecting => _count(
    (GroupMember m) =>
        m.phase == LinkPhase.waiting ||
        m.phase == LinkPhase.connecting ||
        m.phase == LinkPhase.handshaking,
  );
  int get unavailable => _count(
    (GroupMember m) =>
        m.phase == LinkPhase.unavailable ||
        m.phase == LinkPhase.incompatible ||
        m.phase == LinkPhase.bluetoothOff,
  );
  int get limitedOut => _count((GroupMember m) => m.limitedOut);

  int _count(bool Function(GroupMember) test) => members.where(test).length;

  @override
  bool operator ==(Object other) =>
      other is GroupStatus &&
      other.active == active &&
      const ListEquality<GroupMember>().equals(other.members, members) &&
      const ListEquality<String>().equals(other.excluded, excluded) &&
      other.capabilities == capabilities;
  @override
  int get hashCode => Object.hash(
    active,
    Object.hashAll(members),
    Object.hashAll(excluded),
    capabilities,
  );
}

/// A value the ready members share: none (no ready member, or none has
/// it), mixed, or the one value they all have.
@immutable
final class Common<T extends Object> {
  const Common.none() : value = null, mixed = false;
  const Common.mixed() : value = null, mixed = true;
  const Common.of(T this.value) : mixed = false;

  /// [values]: one per member.
  factory Common.from(Iterable<T?> values) {
    final List<T?> all = values.toList();
    if (all.isEmpty || all.every((T? v) => v == null)) {
      return Common<T>.none();
    }
    final T? first = all.first;
    if (first == null) return Common<T>.mixed();
    for (final T? v in all.skip(1)) {
      if (v != first) {
        return Common<T>.mixed();
      }
    }
    return Common<T>.of(first);
  }

  final T? value;
  final bool mixed;
  bool get isNone => value == null && !mixed;

  @override
  bool operator ==(Object other) =>
      other is Common<T> && other.value == value && other.mixed == mixed;
  @override
  int get hashCode => Object.hash(value, mixed);
  @override
  String toString() => mixed ? 'mixed' : (value == null ? 'none' : '$value');
}

/// What the ready members show together (each reader value-equal).
@immutable
final class GroupLook {
  const GroupLook({
    this.brightness = const Common<int>.none(),
    this.anyOn = false,
    this.mode = const Common<int>.none(),
    this.colour = const Common<ColourIntent>.none(),
    this.timerDeadline = const Common<Duration>.none(),
  });

  final Common<int> brightness;
  final bool anyOn;
  final Common<int> mode;
  final Common<ColourIntent> colour;

  /// Scheduler time the sleep timers fire (equal within 2 s).
  final Common<Duration> timerDeadline;

  @override
  bool operator ==(Object other) =>
      other is GroupLook &&
      other.brightness == brightness &&
      other.anyOn == anyOn &&
      other.mode == mode &&
      other.colour == colour &&
      other.timerDeadline == timerDeadline;
  @override
  int get hashCode =>
      Object.hash(brightness, anyOn, mode, colour, timerDeadline);
}

/// How one command went across the group.
@immutable
final class GroupResult {
  const GroupResult({this.ok = 0, this.failed = 0, this.skipped = 0});

  /// Sent (and, where the light answers, confirmed).
  final int ok;
  final int failed;

  /// Not sent: the light cannot do it.
  final int skipped;

  @override
  bool operator ==(Object other) =>
      other is GroupResult &&
      other.ok == ok &&
      other.failed == failed &&
      other.skipped == skipped;
  @override
  int get hashCode => Object.hash(ok, failed, skipped);
  @override
  String toString() => 'GroupResult(ok $ok, failed $failed, skipped $skipped)';
}

/// The last look sent to the group: a colour, or a mode with its settings.
sealed class _Look {
  const _Look();
}

final class _ColourLook extends _Look {
  const _ColourLook(this.intent);
  final ColourIntent intent;
}

final class _ModeLook extends _Look {
  const _ModeLook(this.mode, {this.speed, this.frequency});
  final int mode;
  final int? speed;
  final int? frequency;
}

/// All Lights: one control surface sending the same commands at the same
/// moment to every saved light (of any type) that is not excluded. It
/// broadcasts; each light runs its own effect clock.
final class GroupSession {
  GroupSession({
    required this._registry,
    required this._connections,
    required this._store,
    required this._scheduler,
  }) {
    _excluded = _readIds(excludedKey);
    _following = _readIds(followingKey);
    _own = _readIds(ownKey);
    _trim = <String, double>{
      if (_store.read(trimKey) case final Map<String, Object?> m)
        for (final MapEntry<String, Object?> e in m.entries)
          if (e.value case final num t) e.key: _clampTrim(t.toDouble()),
    };
    _regSub = _registry.changes.listen((_) => _onFixtures());
    _onFixtures();
  }

  /// Fixture ids left out of the group (persisted).
  static const String excludedKey = 'group.excluded';

  /// Lights that got a group command since they last joined (persisted).
  static const String followingKey = 'group.following';

  /// Lights detached by a change on their own controls (persisted).
  static const String ownKey = 'group.own';

  /// Per-light brightness trim, id -> 0.05..1 (persisted; 1 when absent).
  static const String trimKey = 'group.trim';

  static const double minTrim = 0.05;

  /// A timer with less left than this is not sent to a late light.
  static const Duration minCatchUpTimer = Duration(seconds: 5);

  final FixtureRegistry _registry;
  final ConnectionManager _connections;
  final JsonStore _store;
  final Scheduler _scheduler;

  late Set<String> _excluded;
  late Set<String> _following;
  late Set<String> _own;
  late Map<String, double> _trim;
  late final StreamSubscription<List<Fixture>> _regSub;
  final Map<String, StreamSubscription<FixtureStatus>> _subs =
      <String, StreamSubscription<FixtureStatus>>{};
  final Map<String, StreamSubscription<String>> _userSubs =
      <String, StreamSubscription<String>>{};
  final Set<String> _ready = <String>{};
  final Map<String, Want> _wants = <String, Want>{};
  Set<String> _limitedOut = const <String>{};
  bool _active = false;
  bool _disposed = false;

  // What the user sent in this activation (never persisted).
  _Look? _look;
  int? _brightness;
  bool? _power;

  /// Set: a timer was sent; its deadline, or null when it was cancelled.
  (Duration?,)? _timer;

  GroupStatus _status = const GroupStatus();
  GroupLook _groupLook = const GroupLook();
  final StreamController<GroupStatus> _statuses =
      StreamController<GroupStatus>.broadcast();
  final StreamController<GroupLook> _looks =
      StreamController<GroupLook>.broadcast();

  bool get active => _active;

  /// Lights this phone connects at once (the group's budget).
  int get budget => _connections.policy.maxConnections;

  /// Whose timer span the sleep-timer sheet keeps for the group.
  static const String timerSpanKey = 'all-lights';
  GroupStatus get status => _status;
  Stream<GroupStatus> get statuses => _statuses.stream;
  GroupLook get look => _groupLook;
  Stream<GroupLook> get looks => _looks.stream;

  /// Member ids in Home's order.
  List<String> get members => <String>[
    for (final Fixture f in _registry.fixtures)
      if (!_excluded.contains(f.id)) f.id,
  ];

  bool isExcluded(String id) => _excluded.contains(id);
  bool isFollowing(String id) => _following.contains(id);
  bool isOwn(String id) => _own.contains(id);

  /// The light's brightness trim (0.05..1).
  double trimOf(String id) => _trim[id] ?? 1;

  /// Leaves a light out of the group, or takes it back in ([rejoin]).
  void setExcluded(String id, {required bool excluded}) {
    if (_registry.byId(id) == null) return;
    if (!excluded) return rejoin(id);
    if (!_excluded.add(id)) return;
    _following.remove(id);
    _save();
    if (_active) _allocate();
    _emit();
  }

  /// Takes a light back into the group (from its own settings or from being
  /// left out): it follows again and, while the group is active, catches up
  /// with what the group was sent.
  void rejoin(String id) => _rejoin(<String>[id]);

  /// [rejoin] for every light.
  void rejoinAll() =>
      _rejoin(<String>[for (final Fixture f in _registry.fixtures) f.id]);

  void _rejoin(List<String> ids) {
    final List<String> known = ids
        .where((String id) => _registry.byId(id) != null)
        .toList();
    if (known.isEmpty) return;
    for (final String id in known) {
      _own.remove(id);
      _excluded.remove(id);
      _following.add(id);
    }
    _save();
    if (_active) {
      _allocate();
      for (final String id in known) {
        if (_ready.contains(id)) _catchUp(id);
      }
    }
    _emit();
  }

  /// Sets a light's brightness trim; it applies to that light at once.
  void setTrim(String id, double trim) {
    if (_registry.byId(id) == null) return;
    final double t = _clampTrim(trim);
    final double old = trimOf(id);
    if (t == old) return;
    if (t == 1) {
      _trim.remove(id);
    } else {
      _trim[id] = t;
    }
    _save();
    final FixtureSession? s = _connections.session(id);
    final EbDeviceState? st = s?.status.state;
    if (s != null &&
        st != null &&
        !st.sleeping &&
        _ready.contains(id) &&
        _drives(id)) {
      final int master =
          _brightness ?? math.min(255, (st.scene.brightness / old).round());
      s.setBrightness(trimmed(master, t), origin: CommandOrigin.group);
    }
    _emit();
  }

  static double _clampTrim(double t) => t.clamp(minTrim, 1.0);

  /// A light's brightness for the group's [master] at [trim]: never 0 while
  /// the master is above 0; 0 turns it off (its own off-at-zero path).
  static int trimmed(int master, double trim) =>
      master <= 0 ? 0 : math.max(1, (master * trim).round()).clamp(1, 255);

  /// The master every light's (brightness, trim) comes from, if there is
  /// one: trimmed lights read as the same setting, not as mixed.
  static Common<int> commonMaster(List<(int, double)> lights) {
    if (lights.isEmpty) return const Common<int>.none();
    // Candidates from the finest-stepped light (the largest trim).
    final (int b0, double t0) = lights.reduce(
      ((int, double) a, (int, double) b) => a.$2 >= b.$2 ? a : b,
    );
    bool fits(int m) =>
        lights.every(((int, double) l) => trimmed(m, l.$2) == l.$1);
    if (b0 == 0) {
      return fits(0) ? const Common<int>.of(0) : const Common<int>.mixed();
    }
    final int lo = b0 == 1 ? 1 : ((b0 - 0.5) / t0).ceil().clamp(1, 255);
    final int hi = ((b0 + 0.5) / t0).floor().clamp(1, 255);
    final double best = b0 / t0;
    final List<int> candidates = <int>[for (int m = lo; m <= hi; m++) m]
      ..sort((int a, int b) => (a - best).abs().compareTo((b - best).abs()));
    for (final int m in candidates) {
      if (fits(m)) return Common<int>.of(m);
    }
    return const Common<int>.mixed();
  }

  Set<String> _readIds(String key) => <String>{
    ...switch (_store.read(key)) {
      final List<Object?> l => l.whereType<String>(),
      _ => const <String>[],
    },
  };

  /// Connects the members (favourites first, then Home's order) up to the
  /// connection budget; the rest are reported as limited out.
  void activate() {
    if (_active || _disposed) return;
    _active = true;
    _allocate();
    _emit();
  }

  /// Releases every connection the group asked for and forgets what it sent.
  void deactivate() {
    if (!_active) return;
    _active = false;
    _releaseAll();
    _limitedOut = const <String>{};
    _look = null;
    _brightness = null;
    _power = null;
    _timer = null;
    _emit();
  }

  /// Releases everything at once (nothing to wait for).
  void dispose() {
    deactivate();
    _disposed = true;
    unawaited(_regSub.cancel());
    for (final StreamSubscription<FixtureStatus> s in _subs.values) {
      unawaited(s.cancel());
    }
    for (final StreamSubscription<String> s in _userSubs.values) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _userSubs.clear();
    unawaited(_statuses.close());
    unawaited(_looks.close());
  }

  // ---- commands --------------------------------------------------------------------

  Future<GroupResult> setPower({required bool on}) {
    _power = on;
    // Turning off cancels the sleep timers.
    if (!on) _timer = null;
    return _send(
      (FixtureSession s, _) => s.setPower(on: on, origin: CommandOrigin.group),
    );
  }

  /// [v] is the master: each light gets it at its trim. Each keeps its own
  /// off-at-zero handling (a release at 0 turns it off).
  Future<GroupResult> setBrightness(int v, {bool live = false}) {
    _brightness = v;
    return _sendNow(
      (FixtureSession s, _) => s.setBrightness(
        trimmed(v, trimOf(s.fixture.id)),
        live: live,
        origin: CommandOrigin.group,
      ),
    );
  }

  void beginGesture(String key) {
    for (final FixtureSession s in _readySessions) {
      s.beginGesture(key);
    }
  }

  void endGesture(String key) {
    for (final FixtureSession s in _readySessions) {
      s.endGesture(key);
    }
  }

  /// Encoded per light for its layout and LEDs: a colour goes to the lights
  /// with colour LEDs, a white to those and the tunable ones; the others
  /// are skipped.
  Future<GroupResult> setColour(ColourIntent intent, {bool live = false}) {
    _look = _ColourLook(intent);
    return _send((FixtureSession s, _) {
      _sendColour(s, intent, live: live, origin: CommandOrigin.group);
      return Future<EbResult>.value(EbResult.ok);
    }, supported: (FixtureSession s, _) => _applies(intent, s));
  }

  Future<GroupResult> setMode(int mode) {
    _look = _ModeLook(mode);
    return _send(
      (FixtureSession s, _) => s.setMode(mode, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(mode),
    );
  }

  Future<GroupResult> setSpeed(int mode, int v) {
    final _Look? l = _look;
    if (l is _ModeLook && l.mode == mode) {
      _look = _ModeLook(mode, speed: v, frequency: l.frequency);
    }
    return _send(
      (FixtureSession s, _) => s.setSpeed(mode, v, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(mode),
    );
  }

  Future<GroupResult> setFrequency(int mode, int v) {
    final _Look? l = _look;
    if (l is _ModeLook && l.mode == mode) {
      _look = _ModeLook(mode, speed: l.speed, frequency: v);
    }
    return _send(
      (FixtureSession s, _) =>
          s.setFrequency(mode, v, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(mode),
    );
  }

  /// Sleep timer on every ready light; 0 cancels.
  Future<GroupResult> setTimer(int seconds) {
    _timer = (
      seconds > 0 ? _scheduler.now + Duration(seconds: seconds) : null,
    );
    return _send(
      (FixtureSession s, _) => s.setTimer(seconds),
      supported: (_, LightCapabilities c) => c.hasTimer,
    );
  }

  // ---- sending -----------------------------------------------------------------------

  /// The group drives this light: in the group and not on its own settings.
  bool _drives(String id) => !_excluded.contains(id) && !_own.contains(id);

  Iterable<FixtureSession> get _readySessions sync* {
    for (final String id in members) {
      if (!_ready.contains(id) || _own.contains(id)) continue;
      final FixtureSession? s = _connections.session(id);
      if (s != null) yield s;
    }
  }

  static LightCapabilities _capabilities(FixtureSession s) =>
      s.status.view?.firmware?.capabilities ?? s.fixture.capabilities;

  /// Sends to every ready light the group drives that can take it; one
  /// result for all. Each light it reaches follows the group.
  Future<GroupResult> _send(
    Future<EbResult> Function(FixtureSession s, LightCapabilities c) action, {
    bool Function(FixtureSession s, LightCapabilities c)? supported,
  }) async {
    int skipped = 0;
    bool followed = false;
    final List<Future<EbResult>> sent = <Future<EbResult>>[];
    for (final FixtureSession s in _readySessions.toList()) {
      final LightCapabilities c = _capabilities(s);
      if (supported != null && !supported(s, c)) {
        skipped++;
        continue;
      }
      sent.add(action(s, c));
      followed |= _following.add(s.fixture.id);
    }
    if (followed) {
      _save();
      _emit();
    }
    final List<EbResult> results = await Future.wait(sent);
    final int ok = results.where((EbResult r) => r.isSuccess).length;
    return GroupResult(ok: ok, failed: results.length - ok, skipped: skipped);
  }

  /// [_send] for changes that have no reply of their own (streamed).
  Future<GroupResult> _sendNow(
    void Function(FixtureSession s, LightCapabilities c) action,
  ) => _send((FixtureSession s, LightCapabilities c) {
    action(s, c);
    return Future<EbResult>.value(EbResult.ok);
  });

  static GroupLight _groupLight(Fixture f) =>
      GroupLight(f.id, f.layout, f.whitePoints);

  /// Whether [intent] applies to the light at all.
  static bool _applies(ColourIntent intent, FixtureSession s) =>
      GroupCapabilities.intentFor(intent, _groupLight(s.fixture)) != null;

  /// As the colour editor sends it: the encoding for this light, with the
  /// intent as the pick (so the light's own screen shows exactly it).
  static void _sendColour(
    FixtureSession s,
    ColourIntent intent, {
    required bool live,
    required CommandOrigin origin,
  }) {
    final Fixture f = s.fixture;
    final ColourIntent? own = GroupCapabilities.intentFor(
      intent,
      _groupLight(f),
    );
    if (own == null) return;
    final ChannelColor c = ColourEngine(f.whitePoints).encode(own, f.layout);
    s.setColor(c, live: live, intent: own, origin: origin);
  }

  // ---- membership and connections ----------------------------------------------------

  void _onFixtures() {
    if (_disposed) return;
    final Set<String> ids = <String>{
      for (final Fixture f in _registry.fixtures) f.id,
    };
    // Forgotten lights: out of the group's list, their connection released.
    for (final String id in _subs.keys.toList()) {
      if (ids.contains(id)) continue;
      unawaited(_subs.remove(id)!.cancel());
      unawaited(_userSubs.remove(id)?.cancel());
      _ready.remove(id);
      _wants.remove(id)?.release();
    }
    // Every group key forgets lights that are gone.
    if (<String>[
      ..._excluded,
      ..._following,
      ..._own,
      ..._trim.keys,
    ].any((String id) => !ids.contains(id))) {
      _excluded = _excluded.where(ids.contains).toSet();
      _following = _following.where(ids.contains).toSet();
      _own = _own.where(ids.contains).toSet();
      _trim.removeWhere((String id, _) => !ids.contains(id));
      _save();
    }
    for (final String id in ids) {
      if (_subs.containsKey(id)) continue;
      final FixtureSession? s = _connections.session(id);
      if (s == null) continue;
      if (s.status.isReady) _ready.add(id);
      _subs[id] = s.statuses.listen((FixtureStatus st) => _onStatus(id, st));
      _userSubs[id] = s.userLookChanges.listen((_) => _onUserLook(id));
    }
    if (_active) _allocate();
    _emit();
  }

  void _onStatus(String id, FixtureStatus st) {
    final bool ready = st.isReady;
    final bool became = ready && _ready.add(id);
    if (!ready) _ready.remove(id);
    if (became && _active && _drives(id)) _catchUp(id);
    _emit();
  }

  /// The user changed a following light's look on its own controls: it
  /// keeps its own settings until it rejoins (also with All Lights closed).
  void _onUserLook(String id) {
    if (!_following.remove(id)) return;
    _own.add(id);
    _save();
    _emit();
  }

  /// Wants for the first members up to the budget, favourites first.
  void _allocate() {
    final List<Fixture> ordered = <Fixture>[
      for (final Fixture f in _registry.fixtures)
        if (!_excluded.contains(f.id)) f,
    ];
    mergeSort(
      ordered,
      compare: (Fixture a, Fixture b) =>
          a.favourite == b.favourite ? 0 : (a.favourite ? -1 : 1),
    );
    final int budget = _connections.policy.maxConnections;
    final Set<String> keep = ordered
        .take(budget)
        .map((Fixture f) => f.id)
        .toSet();
    for (final String id in _wants.keys.toList()) {
      if (!keep.contains(id)) _wants.remove(id)!.release();
    }
    for (final String id in keep) {
      _wants.putIfAbsent(id, () => _connections.want(id, WantReason.group));
    }
    _limitedOut = ordered.skip(budget).map((Fixture f) => f.id).toSet();
  }

  void _releaseAll() {
    for (final Want w in _wants.values) {
      w.release();
    }
    _wants.clear();
  }

  /// A light the group drives that became ready (or rejoined) gets what the
  /// group was sent, as far as it applies to it: look, brightness (at its
  /// trim), power, then the timer's remaining time. It follows the group.
  void _catchUp(String id) {
    final FixtureSession? s = _connections.session(id);
    if (s == null) return;
    final LightCapabilities caps = _capabilities(s);
    const CommandOrigin origin = CommandOrigin.system;
    bool sent = false;
    switch (_look) {
      case _ColourLook(:final ColourIntent intent) when _applies(intent, s):
        _sendColour(s, intent, live: false, origin: origin);
        sent = true;
      case _ModeLook(:final int mode, :final int? speed, :final int? frequency)
          when caps.supportsMode(mode):
        unawaited(s.setMode(mode, origin: origin));
        if (speed != null) unawaited(s.setSpeed(mode, speed, origin: origin));
        if (frequency != null) {
          unawaited(s.setFrequency(mode, frequency, origin: origin));
        }
        sent = true;
      case _ColourLook() || _ModeLook() || null:
        break;
    }
    final int? b = _brightness;
    if (b != null) {
      s.setBrightness(trimmed(b, trimOf(id)), origin: origin);
      sent = true;
    }
    final bool? on = _power;
    if (on != null) {
      unawaited(s.setPower(on: on, origin: origin));
      sent = true;
    }
    final (Duration?,)? timer = _timer;
    if (timer != null && caps.hasTimer) {
      final Duration? deadline = timer.$1;
      if (deadline == null) {
        if (s.status.state?.timerDeadline != null) unawaited(s.setTimer(0));
      } else {
        final Duration left = deadline - _scheduler.now;
        if (left >= minCatchUpTimer) unawaited(s.setTimer(left.inSeconds));
      }
      sent = true;
    }
    if (sent && _following.add(id)) _save();
  }

  void _save() {
    _store.write(excludedKey, _excluded.toList()..sort());
    _store.write(followingKey, _following.toList()..sort());
    _store.write(ownKey, _own.toList()..sort());
    _store.write(trimKey, <String, Object?>{
      for (final String id in _trim.keys.toList()..sort()) id: _trim[id],
    });
  }

  // ---- what the UI shows -------------------------------------------------------------

  void _emit() {
    if (_disposed) return;
    final List<String> ids = members;
    final List<String> driven = ids.where(_drives).toList();
    final GroupStatus status = GroupStatus(
      active: _active,
      members: <GroupMember>[
        for (final String id in ids)
          GroupMember(
            id,
            _connections.session(id)?.status.phase ?? LinkPhase.idle,
            limitedOut: _limitedOut.contains(id),
            following: _following.contains(id),
            own: _own.contains(id),
          ),
      ],
      excluded: <String>[
        for (final Fixture f in _registry.fixtures)
          if (_excluded.contains(f.id)) f.id,
      ],
      capabilities: GroupCapabilities(<GroupLight>[
        for (final String id in driven)
          if (_registry.byId(id) case final Fixture f) _groupLight(f),
      ]),
    );
    if (status != _status) {
      _status = status;
      _statuses.add(status);
    }
    final GroupLook look = _lookOf(driven);
    if (look != _groupLook) {
      _groupLook = look;
      _looks.add(look);
    }
  }

  GroupLook _lookOf(List<String> ids) {
    final List<FixtureStatus> ready = <FixtureStatus>[];
    final List<Fixture> fixtures = <Fixture>[];
    for (final String id in ids) {
      final FixtureSession? s = _connections.session(id);
      if (s == null || !_ready.contains(id) || s.status.state == null) continue;
      ready.add(s.status);
      fixtures.add(s.fixture);
    }
    final List<EbDeviceState> states = <EbDeviceState>[
      for (final FixtureStatus st in ready) st.state!,
    ];
    // Colour from the lights that have colour LEDs, if any do.
    final bool anyColour = fixtures.any((Fixture f) => f.layout.hasColour);
    return GroupLook(
      brightness: commonMaster(<(int, double)>[
        for (int i = 0; i < states.length; i++)
          (states[i].scene.brightness, trimOf(fixtures[i].id)),
      ]),
      anyOn: states.any(
        (EbDeviceState s) => !s.sleeping && s.scene.brightness > 0,
      ),
      mode: Common<int>.from(states.map((EbDeviceState s) => s.scene.mode)),
      colour: Common<ColourIntent>.from(<ColourIntent>[
        for (int i = 0; i < ready.length; i++)
          if (!anyColour || fixtures[i].layout.hasColour)
            _shownIntent(ready[i], fixtures[i]),
      ]),
      timerDeadline: _commonDeadline(
        states.map((EbDeviceState s) => s.timerDeadline).toList(),
      ),
    );
  }

  /// The colour a light shows as an intent: the pick while the light's
  /// colour is the change that sent it, else read from its channels.
  static ColourIntent _shownIntent(FixtureStatus st, Fixture f) {
    final EbColorOrigin? origin = st.view?.colorOrigin;
    final ColourPick? pick = st.colourPick;
    if (origin != null &&
        origin.byUser &&
        pick != null &&
        pick.seq == origin.seq) {
      return pick.intent;
    }
    return ColourEngine(f.whitePoints).decode(st.state!.scene.color);
  }

  /// Timers firing within 2 s of each other count as one (the earliest).
  static Common<Duration> _commonDeadline(List<Duration?> deadlines) {
    if (deadlines.isEmpty || deadlines.every((Duration? d) => d == null)) {
      return const Common<Duration>.none();
    }
    if (deadlines.any((Duration? d) => d == null)) {
      return const Common<Duration>.mixed();
    }
    final List<Duration> all = deadlines.cast<Duration>();
    final Duration first = all.reduce(
      (Duration a, Duration b) => a < b ? a : b,
    );
    final Duration last = all.reduce((Duration a, Duration b) => a > b ? a : b);
    return last - first <= const Duration(seconds: 2)
        ? Common<Duration>.of(first)
        : const Common<Duration>.mixed();
  }
}
