import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/ble/ble_central.dart';
import '../core/protocol/eb/eb_constants.dart';
import '../core/util/scheduler.dart';

/// Why someone needs the radio scanning, strongest first.
enum ScanNeed {
  /// Add-light flow: find everything, fast.
  addFlow,

  /// Home / switcher visible: fast, only lights we understand.
  panel,

  /// Waiting to reconnect a wanted light.
  reconnect,

  /// Background freshness of "nearby" badges (duty-cycled on iOS).
  presence,
}

enum DeviceClass { electroBright, legacyElectroBright, other }

/// Everything known about one advertising peripheral (merged adverts).
@immutable
final class SeenDevice {
  const SeenDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.serviceUuids,
    required this.manufacturerData,
    required this.lastSeen,
    required this.connectable,
  });

  final String id;
  final String name;

  /// Smoothed RSSI (dBm).
  final int rssi;
  final Set<String> serviceUuids;
  final Uint8List manufacturerData;

  /// Scheduler time of the last advert.
  final Duration lastSeen;
  final bool connectable;

  DeviceClass get deviceClass {
    if (name == Eb.legacyName) return DeviceClass.legacyElectroBright;
    if (serviceUuids.contains(Eb.serviceUuid) ||
        name.startsWith(Eb.namePrefix)) {
      return DeviceClass.electroBright;
    }
    return DeviceClass.other;
  }

  /// 0..4 bars for the UI.
  int get signalBars => rssi >= -60
      ? 4
      : rssi >= -70
      ? 3
      : rssi >= -80
      ? 2
      : rssi >= -90
      ? 1
      : 0;
}

/// A registered scan need; release it when no longer needed.
final class ScanLease {
  ScanLease._(this._owner, this.need);
  final Discovery _owner;
  final ScanNeed need;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(this);
  }
}

/// The only owner of the BLE scan. The scan follows the strongest current
/// need; Android's limit of 5 scan starts per 30 s is respected (we allow 4)
/// so a restart never silently fails.
final class Discovery {
  Discovery({
    required this._central,
    required this._scheduler,
    required this.isAndroid,
    this.extraServices = const <String>[],
  }) {
    _adapterSub = _central.adapterState.listen((BleAdapterState s) {
      _adapter = s;
      _reconfigure();
    });
  }

  final BleCentral _central;
  final Scheduler _scheduler;
  final bool isAndroid;

  /// Service UUIDs of custom profiles, scanned for in addition to NUS.
  List<String> extraServices;

  static const int androidStartsPerWindow = 4;
  static const Duration androidWindow = Duration(seconds: 30);
  static const Duration iosPresenceOn = Duration(seconds: 8);
  static const Duration iosPresenceOff = Duration(seconds: 22);

  BleAdapterState _adapter = BleAdapterState.unknown;
  late final StreamSubscription<BleAdapterState> _adapterSub;
  final List<ScanLease> _leases = <ScanLease>[];
  final Map<String, SeenDevice> _seen = <String, SeenDevice>{};
  final StreamController<SeenDevice> _updates =
      StreamController<SeenDevice>.broadcast();
  final List<Duration> _starts = <Duration>[];

  StreamSubscription<Advertisement>? _scan;
  _ScanConfig? _running;
  Cancelable? _deferred;
  Cancelable? _duty;
  bool _dutyOff = false;
  bool _disposed = false;
  bool _paused = false;

  int scanStarts = 0;

  Stream<SeenDevice> get updates => _updates.stream;
  Iterable<SeenDevice> get devices => _seen.values;
  SeenDevice? seen(String id) => _seen[id];
  bool get isScanning => _scan != null;

  /// The strongest scan need held right now (tests and diagnostics), or
  /// null when no lease is held.
  @visibleForTesting
  ScanNeed? get strongestNeed => _leases.isEmpty
      ? null
      : _leases
            .map((ScanLease l) => l.need)
            .reduce((ScanNeed a, ScanNeed b) => a.index <= b.index ? a : b);

  /// While the app is in the background no scan runs; leases are kept and
  /// the scan resumes with the app.
  bool get paused => _paused;
  set paused(bool value) {
    if (value == _paused) return;
    _paused = value;
    _reconfigure();
  }

  ScanLease acquire(ScanNeed need) {
    final ScanLease lease = ScanLease._(this, need);
    _leases.add(lease);
    _reconfigure();
    return lease;
  }

  void _release(ScanLease lease) {
    _leases.remove(lease);
    _reconfigure();
  }

  /// Seen within [within] of now.
  bool seenRecently(String id, Duration within) {
    final SeenDevice? d = _seen[id];
    return d != null && _scheduler.now - d.lastSeen <= within;
  }

  /// Stops every timer at once (synchronous part of dispose).
  void halt() {
    _disposed = true;
    _deferred?.cancel();
    _duty?.cancel();
  }

  Future<void> dispose() async {
    halt();
    await _adapterSub.cancel();
    await _scan?.cancel();
    unawaited(_updates.close());
  }

  _ScanConfig? _wanted() {
    if (_disposed ||
        _paused ||
        _adapter != BleAdapterState.ready ||
        _leases.isEmpty) {
      return null;
    }
    ScanNeed top = ScanNeed.presence;
    for (final ScanLease l in _leases) {
      if (l.need.index < top.index) top = l.need;
    }
    final List<String> filter = <String>[Eb.serviceUuid, ...extraServices];
    return switch (top) {
      ScanNeed.addFlow => const _ScanConfig(
        <String>[],
        ScanIntensity.lowLatency,
      ),
      ScanNeed.panel => _ScanConfig(filter, ScanIntensity.lowLatency),
      ScanNeed.reconnect => _ScanConfig(filter, ScanIntensity.balanced),
      ScanNeed.presence => _ScanConfig(
        filter,
        ScanIntensity.lowPower,
        dutyCycled: !isAndroid,
      ),
    };
  }

  void _reconfigure() {
    final _ScanConfig? want = _wanted();
    if (want == _running && (want == null || _scan != null || _dutyOff)) {
      return;
    }
    if (want == null) {
      _stop();
      _running = null;
      return;
    }
    if (_running != null && want.dutyCycled == false) _dutyOff = false;
    _start(want);
  }

  void _start(_ScanConfig config) {
    _deferred?.cancel();
    _deferred = null;
    if (isAndroid) {
      final Duration now = _scheduler.now;
      _starts.removeWhere((Duration t) => now - t >= androidWindow);
      if (_starts.length >= androidStartsPerWindow) {
        // Out of budget: keep the current scan and retry when allowed.
        final Duration wait = _starts.first + androidWindow - now;
        _deferred = _scheduler.after(wait, _reconfigure);
        return;
      }
      _starts.add(now);
    }
    _stop();
    _running = config;
    _dutyOff = false;
    scanStarts++;
    _scan = _central
        .scan(services: config.services, intensity: config.intensity)
        .listen(_onAdvert, onError: (Object _) => _stop());
    if (config.dutyCycled) {
      _duty = _scheduler.after(iosPresenceOn, () {
        _stop();
        _dutyOff = true;
        _duty = _scheduler.after(iosPresenceOff, () {
          _dutyOff = false;
          if (_running == config) {
            _running = null;
            _reconfigure();
          }
        });
      });
    }
  }

  void _stop() {
    _duty?.cancel();
    _duty = null;
    final StreamSubscription<Advertisement>? s = _scan;
    _scan = null;
    if (s != null) unawaited(s.cancel());
  }

  void _onAdvert(Advertisement a) {
    final SeenDevice? old = _seen[a.id];
    final SeenDevice merged = SeenDevice(
      id: a.id,
      name: a.name.isNotEmpty ? a.name : (old?.name ?? ''),
      rssi: old == null ? a.rssi : (old.rssi * 0.7 + a.rssi * 0.3).round(),
      serviceUuids: <String>{...?old?.serviceUuids, ...a.serviceUuids},
      manufacturerData: a.manufacturerData.isNotEmpty
          ? a.manufacturerData
          : (old?.manufacturerData ?? Uint8List(0)),
      lastSeen: _scheduler.now,
      connectable: a.connectable,
    );
    _seen[a.id] = merged;
    _updates.add(merged);
  }
}

@immutable
final class _ScanConfig {
  const _ScanConfig(this.services, this.intensity, {this.dutyCycled = false});
  final List<String> services;
  final ScanIntensity intensity;
  final bool dutyCycled;

  @override
  bool operator ==(Object other) =>
      other is _ScanConfig &&
      other.intensity == intensity &&
      other.dutyCycled == dutyCycled &&
      other.services.length == services.length &&
      other.services.every(services.contains);

  @override
  int get hashCode => Object.hash(intensity, dutyCycled, services.length);
}
