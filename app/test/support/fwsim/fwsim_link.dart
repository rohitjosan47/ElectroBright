import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/protocol/eb/eb_ota.dart';
import 'package:electrobright/core/util/scheduler.dart';

import 'fwsim_process.dart';

/// When the firmware's control task runs relative to an app write.
enum PassTiming {
  /// A full pass right after every write (a relaxed device).
  immediate,

  /// A seeded mix of: pass now, defer to a later pass, or land the write in
  /// the middle of a pass — the races BLE callbacks create on the device.
  adversarial,
}

/// A [BleLink] backed by the real firmware core (fwsim). Virtual time: the
/// app's [ManualScheduler] and fwsim's clock move together in [advance].
final class FwSimLink implements BleLink {
  FwSimLink._(this.sim, this.scheduler, this.timing, int seed)
    : _random = Random(seed);

  static Future<FwSimLink> connect(
    FwSim sim,
    ManualScheduler scheduler, {
    PassTiming timing = PassTiming.immediate,
    int seed = 1,
    int mtu = 247,
    Duration subscribeDelay = Duration.zero,
  }) async {
    final FwSimLink link = FwSimLink._(sim, scheduler, timing, seed)
      .._subscribeDelay = subscribeDelay;
    await link._request('AUTO 0');
    await link._request('CONNECT');
    await link._request('PASS');
    await link._request('MTU $mtu');
    link._mtu = mtu;
    return link;
  }

  final FwSim sim;
  final ManualScheduler scheduler;
  final PassTiming timing;
  final Random _random;
  Duration _subscribeDelay = Duration.zero;
  int _mtu = 23;
  final StreamController<Uint8List> _notes =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _otaNotes =
      StreamController<Uint8List>.broadcast();
  final Completer<LinkLossReason> _closed = Completer<LinkLossReason>();
  Future<void> _lock = Future<void>.value();
  int _inFlight = 0;

  /// Test knobs: make the next write(s) fail as if the stack refused them.
  int failNextWrites = 0;

  int writes = 0;
  int writesWithoutResponse = 0;
  final List<Uint8List> written = <Uint8List>[];

  /// App time of each entry of [written].
  final List<Duration> writtenAt = <Duration>[];

  @override
  String get deviceId => 'fwsim';

  @override
  int get mtu => _mtu;

  @override
  Future<LinkLossReason> get closed => _closed.future;

  bool get isClosed => _closed.isCompleted;

  /// No fwsim request outstanding.
  bool get isQuiet => _inFlight == 0;

  @override
  Stream<Uint8List> subscribe(GattRef ref) {
    if (ref.characteristic == EbOta.controlUuid) {
      unawaited(_request('OSUB 1'));
      return _otaNotes.stream;
    }
    if (_subscribeDelay == Duration.zero) {
      unawaited(_request('SUB 1'));
    } else {
      scheduler.after(_subscribeDelay, () => unawaited(_request('SUB 1')));
    }
    return _notes.stream;
  }

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) async {
    if (isClosed) throw const LinkClosedException(LinkLossReason.lost);
    if (failNextWrites > 0) {
      failNextWrites--;
      throw const LinkClosedException(LinkLossReason.failed);
    }
    writes++;
    if (!withResponse) writesWithoutResponse++;
    written.add(value);
    writtenAt.add(scheduler.now);
    final String hex = value
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // The update service: its own characteristics, a pass per write.
    if (ref.characteristic == EbOta.controlUuid) {
      await _request('OC $hex');
      await _request('PASS');
      return;
    }
    if (ref.characteristic == EbOta.dataUuid) {
      await _request('OD $hex');
      if (timing == PassTiming.immediate) await _request('PASS');
      return;
    }
    switch (_decide()) {
      case _Pass.now:
        await _request('W $hex');
        await _request('PASS');
      case _Pass.later:
        await _request('W $hex');
      case _Pass.split:
        await _request('BEGIN');
        await _request('W $hex');
        await _request('END');
    }
  }

  _Pass _decide() {
    if (timing == PassTiming.immediate) return _Pass.now;
    final double x = _random.nextDouble();
    if (x < 0.55) return _Pass.now;
    if (x < 0.85) return _Pass.later;
    return _Pass.split;
  }

  /// Moves app and device time forward together in small steps.
  Future<void> advance(
    Duration d, {
    Duration step = const Duration(milliseconds: 5),
  }) async {
    Duration left = d;
    while (left > Duration.zero) {
      final Duration s = left < step ? left : step;
      left -= s;
      if (!isClosed) await _request('ADV ${s.inMilliseconds}');
      await pump();
      scheduler.advance(s);
      await pump();
    }
  }

  /// The device's view (fwsim STATE).
  Future<Map<String, Object?>> deviceState() async =>
      (await _request('STATE')).state!;

  /// Sounds the device played since the last call.
  Future<List<String>> sounds() async => (await _request('SOUNDS')).sounds!;

  /// Fault injection passthrough (e.g. 'NFAIL 2', 'KVFAIL 1').
  Future<void> inject(String request) => _request(request);

  /// The peripheral vanished (out of range / power loss).
  Future<void> drop() async {
    await _request('DISCONNECT');
    await _request('PASS');
    _finish(LinkLossReason.lost);
  }

  @override
  Future<void> disconnect() async {
    if (isClosed) return;
    await _request('DISCONNECT');
    await _request('PASS');
    _finish(LinkLossReason.requested);
  }

  void _finish(LinkLossReason reason) {
    if (!_closed.isCompleted) _closed.complete(reason);
    unawaited(_notes.close());
    unawaited(_otaNotes.close());
  }

  /// fwsim is one request/response pipe: serialise every request.
  Future<FwSimReply> _request(String line) {
    final Future<void> previous = _lock;
    final Completer<void> mine = Completer<void>();
    _lock = mine.future;
    _inFlight++;
    return previous
        .then((_) => sim.request(line))
        .then((FwSimReply r) {
          for (final Uint8List n in r.notifications) {
            if (!_notes.isClosed) _notes.add(n);
          }
          for (final Uint8List n in r.otaNotifications) {
            if (!_otaNotes.isClosed) _otaNotes.add(n);
          }
          return r;
        })
        .whenComplete(() {
          _inFlight--;
          mine.complete();
        });
  }
}

enum _Pass { now, later, split }

/// Lets queued microtasks, stream events and completed I/O run.
Future<void> pump([int times = 20]) async {
  for (int i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
