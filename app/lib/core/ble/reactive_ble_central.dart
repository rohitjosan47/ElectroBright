import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'ble_central.dart';
import 'ble_link.dart';

/// [BleCentral] on flutter_reactive_ble (BSD-3, Philips Hue).
///
/// Workarounds baked in (see the plan's M2 notes):
/// * never `connectToAdvertisingDevice`: its internal scan fights ours and
///   burns Android's 5-starts-per-30-s scan budget;
/// * the caller serialises connects on Android (ConnectionManager);
/// * our own connect timeout in addition to the plugin's;
/// * writes are serialised per link by LinkWriter; iOS write-without-response
///   has no flow control in the plugin, so the colour lane paces by time.
final class ReactiveBleCentral implements BleCentral {
  ReactiveBleCentral([FlutterReactiveBle? ble])
    : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;
  BleAdapterState _state = BleAdapterState.unknown;

  @override
  BleAdapterState get currentAdapterState => _state;

  @override
  Stream<BleAdapterState> get adapterState =>
      _ble.statusStream.map((BleStatus s) {
        _state = switch (s) {
          BleStatus.unknown => BleAdapterState.unknown,
          BleStatus.unsupported => BleAdapterState.unsupported,
          BleStatus.unauthorized => BleAdapterState.unauthorized,
          BleStatus.poweredOff => BleAdapterState.poweredOff,
          BleStatus.locationServicesDisabled =>
            BleAdapterState.locationServicesDisabled,
          BleStatus.ready => BleAdapterState.ready,
        };
        return _state;
      });

  @override
  Stream<Advertisement> scan({
    List<String> services = const <String>[],
    ScanIntensity intensity = ScanIntensity.balanced,
  }) => _ble
      .scanForDevices(
        withServices: <Uuid>[for (final String s in services) Uuid.parse(s)],
        scanMode: switch (intensity) {
          ScanIntensity.lowPower => ScanMode.lowPower,
          ScanIntensity.balanced => ScanMode.balanced,
          ScanIntensity.lowLatency => ScanMode.lowLatency,
        },
        // Android 12+: BLUETOOTH_SCAN is declared neverForLocation, so no
        // Location Services. Android 11 and older need them to find anything;
        // the radio then reports locationServicesDisabled and BluetoothAccess
        // (app/bluetooth_access.dart) asks for the permissions and shows the
        // user what is missing. Scans are not refused here either way.
        requireLocationServicesEnabled: false,
      )
      .map(
        (DiscoveredDevice d) => Advertisement(
          id: d.id,
          name: d.name,
          rssi: d.rssi,
          serviceUuids: <String>[
            for (final Uuid u in d.serviceUuids) _expand(u.toString()),
          ],
          manufacturerData: d.manufacturerData,
          connectable: d.connectable != Connectable.unavailable,
        ),
      );

  @override
  Future<BleLink> connect(
    String deviceId, {
    required Map<String, List<String>> services,
    Duration? timeout,
    Future<void>? cancel,
  }) {
    final Completer<BleLink> ready = Completer<BleLink>();
    late final _ReactiveBleLink link;
    Timer? guard;
    late final StreamSubscription<ConnectionStateUpdate> sub;
    sub = _ble
        .connectToDevice(
          id: deviceId,
          servicesWithCharacteristicsToDiscover: <Uuid, List<Uuid>>{
            for (final MapEntry<String, List<String>> e in services.entries)
              Uuid.parse(e.key): <Uuid>[
                for (final String c in e.value) Uuid.parse(c),
              ],
          },
          // With a timeout Android connects directly (autoConnect=false):
          // much faster than the background autoConnect path.
          connectionTimeout: timeout,
        )
        .listen(
          (ConnectionStateUpdate u) async {
            switch (u.connectionState) {
              case DeviceConnectionState.connected:
                if (ready.isCompleted) return;
                guard?.cancel();
                link = _ReactiveBleLink(_ble, deviceId, sub);
                try {
                  await link._prepare(services);
                  if (!ready.isCompleted) ready.complete(link);
                } on Object catch (e) {
                  await sub.cancel();
                  if (!ready.isCompleted) {
                    ready.completeError(ConnectException('setup failed: $e'));
                  }
                }
              case DeviceConnectionState.disconnected:
                guard?.cancel();
                if (!ready.isCompleted) {
                  await sub.cancel();
                  ready.completeError(
                    ConnectException(
                      u.failure?.message ?? 'disconnected while connecting',
                      gattStatus: _gattStatus(u.failure?.message),
                    ),
                  );
                } else {
                  link._lost(LinkLossReason.lost);
                }
              case DeviceConnectionState.connecting:
              case DeviceConnectionState.disconnecting:
                break;
            }
          },
          onError: (Object e) {
            guard?.cancel();
            if (!ready.isCompleted) {
              ready.completeError(
                ConnectException('$e', gattStatus: _gattStatus('$e')),
              );
            } else {
              link._lost(LinkLossReason.failed);
            }
          },
        );
    if (timeout != null) {
      guard = Timer(timeout + const Duration(seconds: 1), () {
        if (ready.isCompleted) return;
        unawaited(sub.cancel());
        ready.completeError(const ConnectException('timed out'));
      });
    }
    unawaited(
      cancel?.then((_) {
        if (ready.isCompleted) return;
        guard?.cancel();
        unawaited(sub.cancel());
        ready.completeError(const ConnectException('cancelled'));
      }),
    );
    return ready.future;
  }

  @override
  Future<void> clearCache(String deviceId) async {
    if (!Platform.isAndroid) return;
    try {
      await _ble.clearGattCache(deviceId);
    } on Object {
      // Best effort: hidden API on some ROMs.
    }
  }

  static int? _gattStatus(String? message) {
    if (message == null) return null;
    final RegExpMatch? m = RegExp(r'status[^0-9]*(\d{1,3})')
        .firstMatch(message);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 16-bit UUIDs come back short ("fff0"); keep them short and lower-case,
  /// 128-bit ones lower-case.
  static String _expand(String uuid) => uuid.toLowerCase();
}

final class _ReactiveBleLink implements BleLink {
  _ReactiveBleLink(this._ble, this.deviceId, this._connection);

  final FlutterReactiveBle _ble;
  @override
  final String deviceId;
  final StreamSubscription<ConnectionStateUpdate> _connection;
  final Completer<LinkLossReason> _closed = Completer<LinkLossReason>();
  int _mtu = 23;
  Set<String> _services = const <String>{};

  @override
  int get mtu => _mtu;

  @override
  bool offers(String serviceUuid) => _services.contains(serviceUuid);

  @override
  Future<LinkLossReason> get closed => _closed.future;

  Future<void> _prepare(Map<String, List<String>> services) async {
    await _ble.discoverAllServices(deviceId);
    final List<Service> found = await _ble.getDiscoveredServices(deviceId);
    _services = <String>{
      for (final Service x in found) ReactiveBleCentral._expand('${x.id}'),
    };
    for (final String s in services.keys) {
      if (!found.any((Service x) => x.id == Uuid.parse(s))) {
        throw StateError('service $s missing');
      }
    }
    // Android negotiates here; iOS negotiated on connect and reports it.
    try {
      _mtu = await _ble.requestMtu(deviceId: deviceId, mtu: 247);
    } on Object {
      _mtu = 23;
    }
  }

  QualifiedCharacteristic _q(GattRef r) => QualifiedCharacteristic(
    serviceId: Uuid.parse(r.service),
    characteristicId: Uuid.parse(r.characteristic),
    deviceId: deviceId,
  );

  @override
  Stream<Uint8List> subscribe(GattRef ref) => _ble
      .subscribeToCharacteristic(_q(ref))
      .map((List<int> v) => v is Uint8List ? v : Uint8List.fromList(v));

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) async {
    if (_closed.isCompleted) {
      throw LinkClosedException(await _closed.future);
    }
    try {
      if (withResponse) {
        await _ble.writeCharacteristicWithResponse(_q(ref), value: value);
      } else {
        await _ble.writeCharacteristicWithoutResponse(_q(ref), value: value);
      }
    } on Object {
      if (_closed.isCompleted) throw LinkClosedException(await _closed.future);
      rethrow;
    }
  }

  void _lost(LinkLossReason reason) {
    if (!_closed.isCompleted) _closed.complete(reason);
  }

  @override
  Future<void> disconnect() async {
    _lost(LinkLossReason.requested);
    await _connection.cancel(); // reactive_ble disconnects on cancel
  }
}
