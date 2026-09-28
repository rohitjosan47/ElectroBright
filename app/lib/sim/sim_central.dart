import 'dart:async';
import 'dart:typed_data';

import '../core/ble/ble_central.dart';
import '../core/ble/ble_link.dart';
import '../core/model/channel_layout.dart';
import '../core/protocol/eb/eb_constants.dart';
import '../core/protocol/eb/eb_fixture_catalog.dart';
import '../core/util/scheduler.dart';
import 'eb_device_model.dart';

/// A simulated light for Demo mode and tests: the firmware twin plus radio
/// behaviour (advertising, range, power).
final class SimFixture {
  /// A light running the universal firmware, new with the [fixture] type
  /// (advertised under its type's BLE name unless [name] overrides it).
  SimFixture.electroBright({
    required this.id,
    EbFixtureSpec fixture = EbFixtureCatalog.rgbw,
    this._name,
    this.rssi = -58,
  }) : model = EbDeviceModel(fixture: fixture);

  /// A light whose firmware has no fixture type yet (setup-needed mode).
  SimFixture.setupNeeded({required this.id, this.rssi = -58})
    : _name = null,
      model = EbDeviceModel(fixture: null);

  /// A light still running the original (pre-3.x) ElectroBright firmware:
  /// it advertises `ElectroBright_BLE` and answers INFO with the old model
  /// name, so the app shows "Firmware update needed".
  SimFixture.legacy({required this.id, this.rssi = -66})
    : _name = Eb.legacyName,
      model = EbDeviceModel(fixture: _legacyFirmware);

  static const EbFixtureSpec _legacyFirmware = EbFixtureSpec(
    folder: '(original firmware)',
    fwsimName: 'legacy',
    layout: ChannelLayout.rgbw,
    modelId: Eb.legacyInfo,
    bleName: Eb.legacyName,
    capsReply: 'CAPS:PROTOCOL=0',
    modeMask: 0x1FFF,
    colorValues: <int>[255, 255, 255, 0],
    policeAValues: <int>[255, 165, 0, 0],
    policeBValues: <int>[0, 0, 0, 255],
    legacyFrames: true,
  );

  final String id;
  final String? _name;

  /// Advertised name: the active type's (it changes with SET_TYPE).
  String get name => _name ?? model.fixture.bleName;
  int rssi;
  final EbDeviceModel model;

  /// False = out of range or powered off: no adverts, links drop.
  bool available = true;
  _SimLink? _link;
  bool get connected => _link != null;
}

/// [BleCentral] over simulated lights. Device time follows the [Scheduler]
/// (real time in the app, virtual time in tests).
final class SimCentral implements BleCentral {
  SimCentral({
    required this._scheduler,
    List<SimFixture> fixtures = const <SimFixture>[],
    this.deviceTick = const Duration(milliseconds: 50),
    this.advertInterval = const Duration(milliseconds: 150),
    this.connectDelay = const Duration(milliseconds: 90),
  }) {
    this.fixtures.addAll(fixtures);
    _tickDevices();
  }

  final Scheduler _scheduler;
  final List<SimFixture> fixtures = <SimFixture>[];
  final Duration deviceTick;
  final Duration advertInterval;
  final Duration connectDelay;
  final StreamController<BleAdapterState> _adapter =
      StreamController<BleAdapterState>.broadcast();
  BleAdapterState _state = BleAdapterState.ready;
  bool _disposed = false;
  int connects = 0;
  int scansStarted = 0;

  @override
  BleAdapterState get currentAdapterState => _state;

  @override
  Stream<BleAdapterState> get adapterState {
    // A plain controller (not async*): its cancel completes at once, so
    // disposing the stack never waits on a suspended generator.
    StreamSubscription<BleAdapterState>? inner;
    // Closed by its listener's cancel.
    // ignore: close_sinks
    late final StreamController<BleAdapterState> out;
    out = StreamController<BleAdapterState>(
      onListen: () {
        out.add(_state);
        inner = _adapter.stream.listen(out.add);
      },
      onCancel: () => inner?.cancel(),
    );
    return out.stream;
  }

  /// Tests / demo: switch Bluetooth off or on.
  void setAdapterState(BleAdapterState s) {
    _state = s;
    _adapter.add(s);
    if (s != BleAdapterState.ready) {
      for (final SimFixture f in fixtures) {
        f._link?._drop(LinkLossReason.adapterOff);
      }
    }
  }

  /// Takes a light out of range (drops its link) or brings it back.
  void setAvailable(String id, {required bool available}) {
    final SimFixture f = fixtures.firstWhere((SimFixture x) => x.id == id);
    f.available = available;
    if (!available) f._link?._drop(LinkLossReason.lost);
  }

  /// Power-cycles a light: RAM state lost, link dropped.
  void reboot(String id) {
    final SimFixture f = fixtures.firstWhere((SimFixture x) => x.id == id);
    f._link?._drop(LinkLossReason.lost);
    f.model.reboot();
  }

  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _tick = null;
    for (final Cancelable c in _connectTimers.toList()) {
      c.cancel();
    }
    _connectTimers.clear();
    unawaited(_adapter.close());
  }

  /// Timers of connects in progress (cancelled on dispose).
  final Set<Cancelable> _connectTimers = <Cancelable>{};

  Cancelable _connectTimer(Duration d, void Function() fn) {
    late final Cancelable c;
    c = _scheduler.after(d, () {
      _connectTimers.remove(c);
      fn();
    });
    _connectTimers.add(c);
    return c;
  }

  Cancelable? _tick;

  void _tickDevices() {
    if (_disposed) return;
    _tick = _scheduler.after(deviceTick, () {
      for (final SimFixture f in fixtures) {
        f.model.advance(deviceTick.inMilliseconds);
        f._link?._deliver();
      }
      _tickDevices();
    });
  }

  @override
  Stream<Advertisement> scan({
    List<String> services = const <String>[],
    ScanIntensity intensity = ScanIntensity.balanced,
  }) {
    late final StreamController<Advertisement> out;
    Cancelable? timer;
    void emit() {
      if (_state != BleAdapterState.ready) return;
      for (final SimFixture f in fixtures) {
        if (!f.available || f.connected) continue; // no adverts while connected
        final bool matches =
            services.isEmpty || services.contains(Eb.serviceUuid);
        if (!matches) continue;
        out.add(
          Advertisement(
            id: f.id,
            name: f.name,
            rssi: f.rssi,
            serviceUuids: const <String>[Eb.serviceUuid],
            manufacturerData: Uint8List(0),
            connectable: true,
          ),
        );
      }
    }

    void loop() {
      timer = _scheduler.after(advertInterval, () {
        emit();
        loop();
      });
    }

    out = StreamController<Advertisement>(
      onListen: () {
        scansStarted++;
        emit();
        loop();
      },
      onCancel: () {
        timer?.cancel();
        unawaited(out.close());
      },
    );
    return out.stream;
  }

  @override
  Future<BleLink> connect(
    String deviceId, {
    required Map<String, List<String>> services,
    Duration? timeout,
    Future<void>? cancel,
  }) {
    connects++;
    final Completer<BleLink> ready = Completer<BleLink>();
    final SimFixture? f = fixtures
        .where((SimFixture x) => x.id == deviceId)
        .firstOrNull;
    Cancelable? guard;
    void attempt() {
      if (ready.isCompleted) return;
      if (_disposed) {
        ready.completeError(const ConnectException('disposed'));
        return;
      }
      if (_state != BleAdapterState.ready) {
        ready.completeError(const ConnectException('bluetooth off'));
        return;
      }
      if (f == null || !f.available || f.connected) {
        // Not advertising: keep trying until the timeout (like a pending
        // CoreBluetooth connect).
        _connectTimer(const Duration(milliseconds: 200), attempt);
        return;
      }
      guard?.cancel();
      f.model
        ..connect()
        ..pass();
      final _SimLink link = _SimLink(f, f.model.restarts);
      f._link = link;
      ready.complete(link);
    }

    if (timeout != null) {
      guard = _connectTimer(timeout, () {
        if (!ready.isCompleted) {
          ready.completeError(const ConnectException('timed out'));
        }
      });
    }
    unawaited(
      cancel?.then((_) {
        if (ready.isCompleted) return;
        guard?.cancel();
        ready.completeError(const ConnectException('cancelled'));
      }),
    );
    _connectTimer(connectDelay, attempt);
    return ready.future;
  }

  @override
  Future<void> clearCache(String deviceId) async {}
}

final class _SimLink implements BleLink {
  _SimLink(this._fixture, this._restarts);

  final SimFixture _fixture;

  /// The light's restart count when this link was made: a restart (SET_TYPE)
  /// drops the link.
  final int _restarts;
  final StreamController<Uint8List> _notes =
      StreamController<Uint8List>.broadcast();
  final Completer<LinkLossReason> _closed = Completer<LinkLossReason>();

  @override
  String get deviceId => _fixture.id;

  @override
  int get mtu => 185; // typical iPhone

  @override
  Future<LinkLossReason> get closed => _closed.future;

  @override
  Stream<Uint8List> subscribe(GattRef ref) {
    _fixture.model.setMtu(mtu);
    _fixture.model.setSubscribed(subscribed: true);
    return _notes.stream;
  }

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) async {
    if (_closed.isCompleted) {
      throw LinkClosedException(await _closed.future);
    }
    _fixture.model
      ..write(value)
      ..pass();
    await Future<void>.value();
    _deliver();
  }

  void _deliver() {
    for (final Uint8List n in _fixture.model.takeNotifications()) {
      if (!_notes.isClosed) _notes.add(n);
    }
    if (_fixture.model.restarts != _restarts) _drop(LinkLossReason.lost);
  }

  void _drop(LinkLossReason reason) {
    if (_closed.isCompleted) return;
    _fixture.model
      ..disconnect()
      ..pass();
    _fixture._link = null;
    _closed.complete(reason);
    unawaited(_notes.close());
  }

  @override
  Future<void> disconnect() async => _drop(LinkLossReason.requested);
}
