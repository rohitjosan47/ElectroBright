import 'dart:async';

import '../core/model/fixture.dart';
import '../core/store/json_store.dart';
import '../drivers/electrobright/eb_types.dart';
import 'connection_manager.dart';
import 'device_state_json.dart';
import 'fixture_session.dart';

/// A saved light's firmware turned out to be another fixture type (the board
/// was reflashed): its type is updated and its per-light data dropped.
final class LayoutChange {
  const LayoutChange(this.before, this.after);
  final Fixture before;
  final Fixture after;
}

/// The saved lights: persisted in the [JsonStore], registered with the
/// [ConnectionManager], and kept up to date with what each light's firmware
/// reports (type, capabilities, model, version) and its last-known state.
final class FixtureRegistry {
  FixtureRegistry({
    required this._store,
    required this._connections,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    final Object? saved = _store.read(fixturesCollection);
    if (saved is List<Object?>) {
      for (final Object? j in saved) {
        final Fixture? f = Fixture.fromJson(j);
        if (f != null && !_fixtures.containsKey(f.id)) _fixtures[f.id] = f;
      }
    }
    final Object? known = _store.read(lastKnownCollection);
    for (final Fixture f in _fixtures.values) {
      _attach(f);
      if (known is Map<String, Object?>) {
        final EbDeviceState? st = DeviceStateJson.fromJson(known[f.id]);
        if (st != null) _connections.session(f.id)?.seedLastKnown(st);
      }
    }
  }

  static const String fixturesCollection = 'fixtures';
  static const String lastKnownCollection = 'lastKnown';

  /// Collections keyed by fixture id that belong to one light (dropped when
  /// the light is forgotten or changes type).
  static const List<String> perLightCollections = <String>[
    lastKnownCollection,
    'presetMeta',
    'colourRecents',
  ];

  final JsonStore _store;
  final ConnectionManager _connections;
  final DateTime Function() _clock;
  final Map<String, Fixture> _fixtures = <String, Fixture>{};
  final Map<String, StreamSubscription<FixtureStatus>> _subs =
      <String, StreamSubscription<FixtureStatus>>{};
  final StreamController<List<Fixture>> _changes =
      StreamController<List<Fixture>>.broadcast();
  final StreamController<LayoutChange> _layoutChanges =
      StreamController<LayoutChange>.broadcast();

  List<Fixture> get fixtures => List<Fixture>.unmodifiable(_fixtures.values);
  Stream<List<Fixture>> get changes => _changes.stream;
  Stream<LayoutChange> get layoutChanges => _layoutChanges.stream;

  Fixture? byId(String id) => _fixtures[id];
  Fixture? byDevice(String deviceId) {
    for (final Fixture f in _fixtures.values) {
      if (f.deviceId == deviceId) return f;
    }
    return null;
  }

  void add(Fixture f) {
    _fixtures[f.id] = f;
    _attach(f);
    _persist();
  }

  /// Rename, icon, favourite, LED calibration...
  void update(Fixture f) {
    if (!_fixtures.containsKey(f.id)) return;
    _fixtures[f.id] = f;
    _connections.register(f);
    _persist();
  }

  Future<void> forget(String id) async {
    if (_fixtures.remove(id) == null) return;
    await _subs.remove(id)?.cancel();
    await _connections.unregister(id);
    _dropPerLight(id);
    _persist();
  }

  /// Saves every light's current state (call when the app goes to the
  /// background), then writes the store.
  Future<void> saveAll() {
    for (final Fixture f in _fixtures.values) {
      final EbDeviceState? st = _connections.session(f.id)?.status.state;
      if (st != null) _saveLastKnown(f.id, st);
    }
    return _store.flush();
  }

  Future<void> dispose() async {
    for (final StreamSubscription<FixtureStatus> s in _subs.values) {
      await s.cancel();
    }
    await _changes.close();
    await _layoutChanges.close();
  }

  // ---------------------------------------------------------------------------

  void _attach(Fixture f) {
    _connections.register(f);
    final FixtureSession? s = _connections.session(f.id);
    if (s == null) return;
    unawaited(_subs[f.id]?.cancel());
    _subs[f.id] = s.statuses.listen((FixtureStatus st) => _onStatus(f.id, st));
  }

  void _onStatus(String id, FixtureStatus st) {
    final EbFirmware? fw = st.view?.firmware;
    if (fw != null) _learn(id, fw);
    // Disconnected: keep what the light last confirmed.
    if (st.phase != LinkPhase.ready && st.lastKnown != null) {
      _saveLastKnown(id, st.lastKnown!);
    }
  }

  void _learn(String id, EbFirmware fw) {
    final Fixture? f = _fixtures[id];
    if (f == null) return;
    final FixtureIdentity identity = FixtureIdentity(
      capabilities: fw.capabilities,
      model: fw.model,
      firmwareVersion: fw.version.version,
      caps: fw.caps.fields.entries
          .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
          .join(','),
      learnedAt: f.identity?.learnedAt ?? _clock(),
    );
    final bool typeChanged =
        fw.layout != f.layout && f.identity != null && !f.identity!.assumed;
    final bool same =
        f.layout == fw.layout &&
        f.identity != null &&
        !f.identity!.assumed &&
        f.identity!.capabilities == identity.capabilities &&
        f.identity!.model == identity.model &&
        f.identity!.firmwareVersion == identity.firmwareVersion &&
        f.identity!.caps == identity.caps;
    if (same) return;
    final Fixture next = f.copyWith(
      layout: fw.layout,
      identity: identity,
      lastConnectedAt: _clock(),
    );
    _fixtures[id] = next;
    _connections.session(id)?.fixture = next;
    if (fw.layout != f.layout) _dropPerLight(id);
    if (typeChanged) _layoutChanges.add(LayoutChange(f, next));
    _persist();
  }

  void _saveLastKnown(String id, EbDeviceState st) {
    final Fixture? f = _fixtures[id];
    if (f == null || st.scene.layout != f.layout) return;
    final Map<String, Object?> all = _map(lastKnownCollection);
    all[id] = DeviceStateJson.toJson(st);
    _store.write(lastKnownCollection, all);
  }

  void _dropPerLight(String id) {
    for (final String c in perLightCollections) {
      final Map<String, Object?> all = _map(c);
      if (all.remove(id) != null) _store.write(c, all);
    }
  }

  Map<String, Object?> _map(String collection) {
    final Object? v = _store.read(collection);
    return v is Map<String, Object?>
        ? Map<String, Object?>.of(v)
        : <String, Object?>{};
  }

  void _persist() {
    _store.write(fixturesCollection, <Object?>[
      for (final Fixture f in _fixtures.values) f.toJson(),
    ]);
    if (!_changes.isClosed) _changes.add(fixtures);
  }
}
