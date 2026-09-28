import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bootstrap/service_registry.dart';
import '../core/firmware/firmware_bundle.dart';
import '../core/store/json_store.dart';
import '../core/store/legacy_import.dart';
import '../core/store/preset_reset.dart';
import '../sessions/firmware_update.dart';
import '../sessions/fixture_registry.dart';
import '../sessions/group_session.dart';
import 'bluetooth_access.dart';

/// Everything that exists once the user chose real or demo lights.
final class AppSession {
  AppSession._({
    required this.demo,
    required this.store,
    required this.ble,
    required this.registry,
    required this.groups,
    required this.updates,
    this.bluetooth,
    this.firmware,
  });

  final bool demo;
  final JsonStore store;
  final BleStack ble;
  final FixtureRegistry registry;

  /// The colour and white groups (created and disposed with the session).
  final GroupSessions groups;

  /// Wireless firmware updates (one light at a time).
  final FirmwareUpdates updates;

  /// The firmware bundled with the app (null if it has none).
  final FirmwareBundle? firmware;

  /// Permission and Bluetooth prompts (real lights only).
  final BluetoothAccess? bluetooth;
}

/// Reads the bundled firmware's manifest (tests override it).
final Provider<Future<FirmwareBundle?> Function()> firmwareBundleLoader =
    Provider<Future<FirmwareBundle?> Function()>(
      (Ref ref) =>
          () => FirmwareBundle.load(
            text: (String path) => rootBundle.loadString(path, cache: false),
            bytes: rootBundle.load,
          ),
    );

/// The app's main store (settings, and the real lights), opened in main().
final Provider<JsonStore> storeProvider = Provider<JsonStore>(
  (Ref ref) => throw UnimplementedError('overridden in main()'),
);

/// Opens demo mode's own store (never mixed with real lights).
final Provider<Future<JsonStore> Function()> demoStoreProvider =
    Provider<Future<JsonStore> Function()>(
      (Ref ref) =>
          () async => JsonStore.memory(),
    );

/// Previous-app data source (null in tests / when there is nothing).
final Provider<Future<LegacyPrefs?> Function()> legacyPrefsProvider =
    Provider<Future<LegacyPrefs?> Function()>(
      (Ref ref) => SharedPrefsLegacy.load,
    );

/// Owns the running [AppSession] and shuts it down with the app (tests,
/// hot restart): saves every light's state, then stops Bluetooth.
final class _Runtime {
  _Runtime(this._services);
  final AppServices _services;
  AppSession? session;

  void dispose() {
    final AppSession? s = session;
    session = null;
    if (s == null) return;
    unawaited(s.updates.dispose());
    unawaited(s.bluetooth?.dispose());
    s.groups.dispose();
    unawaited(
      s.registry.saveAll().whenComplete(() async {
        await s.registry.dispose();
        await _services.stopBle();
      }),
    );
  }
}

final Provider<_Runtime> _runtimeProvider = Provider<_Runtime>((Ref ref) {
  final _Runtime r = _Runtime(ref.read(servicesProvider));
  ref.onDispose(r.dispose);
  return r;
});

/// Onboarding state and the running [AppSession].
final NotifierProvider<AppController, AppSession?> appSessionProvider =
    NotifierProvider<AppController, AppSession?>(AppController.new);

final class AppController extends Notifier<AppSession?> {
  static const String onboardedKey = 'onboarded';
  static const String demoKey = 'demo';

  Future<void>? _starting;

  /// Read once, when the app first starts a session.
  Future<FirmwareBundle?>? _bundle;

  _Runtime get _runtime => ref.read(_runtimeProvider);

  @override
  AppSession? build() {
    final Map<String, Object?> settings = _settings();
    if (settings[onboardedKey] == true) {
      final bool demo = settings[demoKey] == true;
      // Resume where the user left off (after the first frame).
      scheduleMicrotask(() => unawaited(start(demo: demo)));
    }
    return null;
  }

  /// True once the user has picked real or demo lights.
  bool get onboarded => _settings()[onboardedKey] == true;

  Map<String, Object?> _settings() {
    final Object? v = ref.read(storeProvider).read('settings');
    return v is Map<String, Object?>
        ? Map<String, Object?>.of(v)
        : <String, Object?>{};
  }

  /// "Use my lights": starts with real lights and asks for what Bluetooth
  /// needs (Android: the permission, then switching it on).
  Future<void> useMyLights() async {
    await start(demo: false);
    await state?.bluetooth?.ensure();
  }

  /// Starts the Bluetooth stack with real lights (this is what shows the iOS
  /// permission prompt) or with demo lights.
  Future<void> start({required bool demo}) {
    if (state != null && state!.demo == demo) return Future<void>.value();
    return _starting ??= _start(demo).whenComplete(() => _starting = null);
  }

  Future<void> _start(bool demo) async {
    final AppServices services = ref.read(servicesProvider);
    final JsonStore main = ref.read(storeProvider);
    final AppSession? old = state;
    if (old != null) {
      state = _runtime.session = null;
      await old.updates.dispose();
      await old.bluetooth?.dispose();
      old.groups.dispose();
      await old.registry.saveAll();
      await old.registry.dispose();
    }
    final JsonStore store = demo ? await ref.read(demoStoreProvider)() : main;
    // One-time startup work, before anything reads the store's presets.
    PresetReset.run(store);
    final BleStack ble = await services.startBle(demo: demo);
    final FixtureRegistry registry = FixtureRegistry(
      store: store,
      connections: ble.connections,
    );
    if (!demo) {
      final LegacyPrefs? prefs = await ref.read(legacyPrefsProvider)();
      if (prefs != null) {
        LegacyImport.run(
          prefs: prefs,
          store: store,
          existing: registry.fixtures,
          addFixture: registry.add,
          newId: newFixtureId,
        );
      }
    }
    final FirmwareBundle? firmware = await (_bundle ??= ref.read(
      firmwareBundleLoader,
    )());
    final Map<String, Object?> settings = _settings()
      ..[onboardedKey] = true
      ..[demoKey] = demo;
    main.write('settings', settings);
    state = _runtime.session = AppSession._(
      demo: demo,
      store: store,
      ble: ble,
      registry: registry,
      groups: GroupSessions(
        registry: registry,
        connections: ble.connections,
        store: store,
        scheduler: services.scheduler,
      ),
      updates: FirmwareUpdates(
        connections: ble.connections,
        scheduler: services.scheduler,
        // A transfer keeps the screen on: auto-lock would suspend the app.
        onRunning: (bool on) => services.platform.setKeepAwake(on: on),
      ),
      firmware: firmware,
      bluetooth: demo
          ? null
          : BluetoothAccess(platform: services.platform, central: ble.central),
    );
  }

  /// App going to the background: save every light's state now.
  Future<void> saveAll() async {
    await state?.registry.saveAll();
    await ref.read(storeProvider).flush();
  }
}

final Random _ids = Random.secure();

/// A new app-level fixture id.
String newFixtureId() =>
    'fx-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${_ids.nextInt(1 << 30).toRadixString(36)}';

/// [LegacyPrefs] over the legacy SharedPreferences API.
final class SharedPrefsLegacy implements LegacyPrefs {
  SharedPrefsLegacy._(this._prefs);
  final SharedPreferences _prefs;

  static Future<LegacyPrefs?> load() async {
    try {
      return SharedPrefsLegacy._(await SharedPreferences.getInstance());
    } on Object {
      return null; // no previous app data store on this platform
    }
  }

  @override
  Set<String> getKeys() => _prefs.getKeys();
  @override
  String? getString(String key) {
    final Object? v = _prefs.get(key);
    return v is String ? v : null;
  }

  @override
  List<String>? getStringList(String key) {
    final Object? v = _prefs.get(key);
    return v is List ? v.whereType<String>().toList() : null;
  }
}
