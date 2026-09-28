import 'dart:async';
import 'dart:typed_data';

import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/ble/link_writer.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/protocol/eb/eb_frame.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/stream_lane.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 10]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const GattRef _rx = GattRef('svc', 'rx');

final class _Write {
  _Write(this.ref, this.value, this.withResponse);
  final GattRef ref;
  final Uint8List value;
  final bool withResponse;
  final Completer<void> done = Completer<void>();
}

/// Records every write. With [manual] each write stays in flight until the
/// test completes it; otherwise it is acknowledged at once. [failNext] makes
/// the next write fail.
final class _FakeLink implements BleLink {
  bool manual = false;
  bool failNext = false;
  final List<_Write> writes = <_Write>[];

  _Write get last => writes.last;

  @override
  String get deviceId => 'dev';
  @override
  int get mtu => 185;
  @override
  bool offers(String serviceUuid) => true;
  @override
  Stream<Uint8List> subscribe(GattRef ref) => const Stream<Uint8List>.empty();
  @override
  Future<LinkLossReason> get closed => Completer<LinkLossReason>().future;
  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) {
    final _Write w = _Write(ref, value, withResponse);
    writes.add(w);
    if (failNext) {
      failNext = false;
      w.done.completeError(const LinkClosedException(LinkLossReason.failed));
    } else if (!manual) {
      w.done.complete();
    }
    return w.done.future;
  }
}

final class _Rig {
  _Rig({
    Duration minGap = const Duration(milliseconds: 25),
    Duration idleFlush = const Duration(milliseconds: 120),
  }) {
    writer = LinkWriter(link);
    lane = StreamLane(
      writer: writer,
      rx: _rx,
      scheduler: clock,
      desired: () => desired,
      onDelivered: delivered.add,
      minGap: minGap,
      idleFlush: idleFlush,
    );
  }

  final ManualScheduler clock = ManualScheduler();
  final _FakeLink link = _FakeLink();
  late final LinkWriter writer;
  late final StreamLane lane;
  StreamValue desired = (color: ChannelColor.rgbw(0, 0, 0, 0), brightness: 0);
  final List<StreamValue> delivered = <StreamValue>[];

  void set(int r, {int brightness = 200}) =>
      desired = (color: ChannelColor.rgbw(r, 0, 0, 0), brightness: brightness);

  /// The red channel of write [i] (frame layout: magic, seq, r, g, b, w, br, x).
  int red(int i) => link.writes[i].value[2];
}

void main() {
  test('a submit writes one frame at once, built from the desired value, '
      'without response', () async {
    final _Rig r = _Rig()..set(10, brightness: 99);
    expect(r.lane.isIdle, isTrue);
    r.lane.submit();
    expect(r.link.writes, hasLength(1));
    expect(r.link.last.ref, _rx);
    expect(r.link.last.withResponse, isFalse);
    expect(
      r.link.last.value,
      EbFrame.encode(0, ChannelColor.rgbw(10, 0, 0, 0), 99),
    );
    await _pump();
    expect(r.lane.framesWritten, 1);
    expect(r.lane.reliableFrames, 0);
    expect(r.delivered, isEmpty, reason: 'unreliable frames are not reported');
    expect(r.lane.isIdle, isFalse, reason: 'not yet written reliably');
  });

  test('latest wins: submits while a frame is in flight coalesce into one '
      'frame carrying the value current when it is written', () async {
    final _Rig r = _Rig();
    r.link.manual = true;
    r.set(1);
    r.lane.submit();
    for (int v = 2; v <= 6; v++) {
      r.set(v);
      r.lane.submit();
    }
    expect(r.link.writes, hasLength(1));
    r.link.writes[0].done.complete();
    await _pump();
    // The gap after the first frame has not passed yet.
    expect(r.link.writes, hasLength(1));
    r.set(7);
    r.clock.advance(const Duration(milliseconds: 25));
    expect(r.link.writes, hasLength(2));
    expect(r.red(1), 7, reason: 'read at write time, never a stale cache');
    expect(r.link.writes[1].value[1], 1, reason: 'sequence number');
  });

  test('frames are spaced by at least minGap after the previous write '
      'completed', () async {
    final _Rig r = _Rig(minGap: const Duration(milliseconds: 40));
    r.lane.submit();
    await _pump();
    r.clock.advance(const Duration(milliseconds: 10));
    r.set(5);
    r.lane.submit();
    expect(r.link.writes, hasLength(1));
    r.clock.advance(const Duration(milliseconds: 29));
    expect(r.link.writes, hasLength(1));
    r.clock.advance(const Duration(milliseconds: 1));
    expect(r.link.writes, hasLength(2));
    expect(r.red(1), 5);
    // Several submits during the gap arm only one timer: still one frame.
    await _pump();
    r.lane
      ..submit()
      ..submit()
      ..submit();
    r.clock.advance(const Duration(milliseconds: 40));
    await _pump();
    expect(r.link.writes, hasLength(3));
  });

  test('a terminal submit is written with response and reported as '
      'delivered; the lane is idle afterwards', () async {
    final _Rig r = _Rig()..set(42, brightness: 7);
    r.lane.submit(terminal: true);
    expect(r.link.last.withResponse, isTrue);
    await _pump();
    expect(r.lane.reliableFrames, 1);
    expect(r.delivered, <StreamValue>[
      (color: ChannelColor.rgbw(42, 0, 0, 0), brightness: 7),
    ]);
    expect(r.lane.isIdle, isTrue);
    // Nothing more is written later.
    r.clock.advance(const Duration(seconds: 1));
    await _pump();
    expect(r.link.writes, hasLength(1));
  });

  test('a terminal flag set by any coalesced submit makes the next frame '
      'reliable', () async {
    final _Rig r = _Rig();
    r.link.manual = true;
    r.lane.submit();
    r.lane.submit(terminal: true);
    r.lane.submit();
    r.link.writes[0].done.complete();
    await _pump();
    r.clock.advance(const Duration(milliseconds: 25));
    expect(r.link.writes, hasLength(2));
    expect(r.link.writes[1].withResponse, isTrue);
  });

  test('after idleFlush of quiet an unreliable last frame is repeated with '
      'response', () async {
    final _Rig r = _Rig()..set(9);
    r.lane.submit();
    await _pump();
    r.clock.advance(const Duration(milliseconds: 119));
    expect(r.link.writes, hasLength(1));
    r.set(11);
    r.clock.advance(const Duration(milliseconds: 1));
    expect(r.link.writes, hasLength(2));
    expect(r.link.last.withResponse, isTrue);
    expect(r.red(1), 11, reason: 'the flush carries the desired value');
    await _pump();
    expect(r.delivered.single.color, ChannelColor.rgbw(11, 0, 0, 0));
    expect(r.lane.isIdle, isTrue);
    // No further flush once everything is reliable.
    r.clock.advance(const Duration(seconds: 2));
    await _pump();
    expect(r.link.writes, hasLength(2));
  });

  test('a new submit postpones the idle flush until quiet again', () async {
    final _Rig r = _Rig();
    r.lane.submit();
    await _pump();
    r.clock.advance(const Duration(milliseconds: 100));
    r.lane.submit();
    await _pump();
    expect(r.link.writes, hasLength(2));
    r.clock.advance(const Duration(milliseconds: 100));
    expect(r.link.writes, hasLength(2), reason: 'flush not due at 200 ms');
    r.clock.advance(const Duration(milliseconds: 20));
    expect(r.link.writes, hasLength(3));
    expect(r.link.last.withResponse, isTrue);
  });

  test('sequence numbers count up and wrap after 255', () async {
    final _Rig r = _Rig(minGap: Duration.zero);
    for (int i = 0; i < 258; i++) {
      r.lane.submit();
      await _pump(3);
    }
    expect(r.link.writes, hasLength(258));
    expect(r.link.writes[0].value[1], 0);
    expect(r.link.writes[255].value[1], 255);
    expect(r.link.writes[256].value[1], 0);
    expect(r.link.writes[257].value[1], 1);
  });

  group('holds (pauseLanes)', () {
    test('hold blocks frames; release sends the latest value', () async {
      final _Rig r = _Rig();
      r.lane.hold();
      r.set(3);
      r.lane.submit();
      r.clock.advance(const Duration(seconds: 1));
      await _pump();
      expect(r.link.writes, isEmpty);
      r.set(4);
      r.lane.release();
      expect(r.link.writes, hasLength(1));
      expect(r.red(0), 4);
    });

    test('holds nest: frames resume only after every hold is released; '
        'extra releases are harmless', () async {
      final _Rig r = _Rig();
      r.lane
        ..hold()
        ..hold()
        ..submit()
        ..release();
      expect(r.link.writes, isEmpty);
      r.lane.release();
      expect(r.link.writes, hasLength(1));
      await _pump();
      r.lane
        ..release()
        ..release();
      r.clock.advance(const Duration(milliseconds: 25));
      r.lane.submit();
      expect(r.link.writes, hasLength(2), reason: 'hold count never negative');
    });

    test('a hold does not stop a frame already in flight', () async {
      final _Rig r = _Rig();
      r.link.manual = true;
      r.lane.submit();
      r.lane.hold();
      r.link.writes[0].done.complete();
      await _pump();
      expect(r.lane.framesWritten, 1);
    });
  });

  group('fenceAndHold', () {
    test('when idle it completes at once and takes a hold', () async {
      final _Rig r = _Rig();
      bool done = false;
      unawaited(r.lane.fenceAndHold().then((_) => done = true));
      await _pump();
      expect(done, isTrue);
      expect(r.link.writes, isEmpty, reason: 'nothing to fence');
      r.lane.submit();
      expect(r.link.writes, isEmpty, reason: 'held');
      r.lane.release();
      expect(r.link.writes, hasLength(1));
    });

    test('with an unreliable frame outstanding it writes the latest value '
        'with response, then completes holding the lane', () async {
      final _Rig r = _Rig()..set(1);
      r.lane.submit();
      await _pump();
      r.clock.advance(const Duration(milliseconds: 30));
      r.set(2);
      bool done = false;
      unawaited(r.lane.fenceAndHold().then((_) => done = true));
      expect(r.link.writes, hasLength(2));
      expect(r.link.last.withResponse, isTrue);
      expect(r.red(1), 2);
      await _pump();
      expect(done, isTrue);
      expect(r.delivered.single.color, ChannelColor.rgbw(2, 0, 0, 0));
      // Held: neither submits nor the idle flush write anything.
      r.set(3);
      r.lane.submit();
      r.clock.advance(const Duration(seconds: 1));
      await _pump();
      expect(r.link.writes, hasLength(2));
      r.lane.release();
      expect(r.link.writes, hasLength(3));
      expect(r.red(2), 3);
    });

    test('requested while a frame is in flight, it waits for a fresh '
        'reliable frame after it', () async {
      final _Rig r = _Rig();
      r.link.manual = true;
      r.set(5);
      r.lane.submit(terminal: true);
      bool done = false;
      unawaited(r.lane.fenceAndHold().then((_) => done = true));
      r.link.writes[0].done.complete();
      await _pump();
      expect(r.lane.reliableFrames, 1);
      expect(done, isFalse, reason: 'the in-flight frame does not count');
      r.set(6);
      r.clock.advance(const Duration(milliseconds: 25));
      expect(r.link.writes, hasLength(2));
      expect(r.link.last.withResponse, isTrue);
      expect(r.red(1), 6);
      r.link.writes[1].done.complete();
      await _pump();
      expect(done, isTrue);
    });

    test('a second fence during the first fence frame costs one more '
        'reliable frame; then both complete, each owning a hold', () async {
      final _Rig r = _Rig();
      r.lane.submit();
      await _pump();
      r.clock.advance(const Duration(milliseconds: 25));
      r.link.manual = true;
      int done = 0;
      unawaited(r.lane.fenceAndHold().then((_) => done++));
      unawaited(r.lane.fenceAndHold().then((_) => done++));
      expect(r.link.writes, hasLength(2));
      r.link.writes[1].done.complete();
      await _pump();
      expect(done, 0);
      r.clock.advance(const Duration(milliseconds: 25));
      expect(r.link.writes, hasLength(3));
      expect(r.link.writes[2].withResponse, isTrue);
      r.link.writes[2].done.complete();
      await _pump();
      expect(done, 2);
      r.clock.advance(const Duration(milliseconds: 25));
      r.lane
        ..submit()
        ..release();
      expect(r.link.writes, hasLength(3), reason: 'one hold left');
      r.lane.release();
      expect(r.link.writes, hasLength(4));
    });

    test('while held by pauseLanes a fence waits for the release', () async {
      final _Rig r = _Rig();
      r.lane.hold();
      bool done = false;
      unawaited(r.lane.fenceAndHold().then((_) => done = true));
      await _pump();
      r.clock.advance(const Duration(seconds: 1));
      expect(done, isFalse);
      expect(r.link.writes, isEmpty);
      r.lane.release();
      expect(r.link.writes, hasLength(1));
      expect(r.link.last.withResponse, isTrue);
      await _pump();
      expect(done, isTrue);
    });
  });

  group('close and errors', () {
    test('close fails pending fences; later fences fail and submits are '
        'ignored', () async {
      final _Rig r = _Rig();
      r.link.manual = true;
      r.lane.submit();
      final Future<void> fence = r.lane.fenceAndHold();
      r.lane.close();
      await expectLater(
        fence,
        throwsA(
          isA<LinkClosedException>().having(
            (LinkClosedException e) => e.reason,
            'reason',
            LinkLossReason.failed,
          ),
        ),
      );
      await expectLater(
        r.lane.fenceAndHold(),
        throwsA(isA<LinkClosedException>()),
      );
      r.link.writes[0].done.complete();
      await _pump();
      r.lane.submit(terminal: true);
      r.clock.advance(const Duration(seconds: 1));
      await _pump();
      expect(r.link.writes, hasLength(1));
    });

    test('close cancels a pending gap timer and the idle flush', () async {
      final _Rig r = _Rig();
      r.lane.submit();
      await _pump();
      r.lane.submit(); // waits for the gap
      r.lane.close();
      r.clock.advance(const Duration(seconds: 1));
      await _pump();
      expect(r.link.writes, hasLength(1));

      final _Rig r2 = _Rig();
      r2.lane.submit();
      await _pump();
      r2.lane.close();
      r2.clock.advance(const Duration(seconds: 1));
      await _pump();
      expect(r2.link.writes, hasLength(1), reason: 'no idle flush');
    });

    test('a failed write is not counted or reported; the lane keeps going '
        'after the gap', () async {
      final _Rig r = _Rig();
      r.link.failNext = true;
      r.lane.submit(terminal: true);
      await _pump();
      expect(r.lane.framesWritten, 0);
      expect(r.lane.reliableFrames, 0);
      expect(r.delivered, isEmpty);
      r.clock.advance(const Duration(seconds: 1));
      await _pump();
      expect(r.link.writes, hasLength(1), reason: 'no retry of its own');
      r.lane.submit(terminal: true);
      expect(r.link.writes, hasLength(2));
      await _pump();
      expect(r.lane.reliableFrames, 1);
    });

    test('a fence whose frame failed is completed by the idle flush when '
        'unreliable frames were outstanding', () async {
      final _Rig r = _Rig();
      r.lane.submit();
      await _pump();
      r.clock.advance(const Duration(milliseconds: 25));
      r.link.failNext = true;
      bool done = false;
      unawaited(r.lane.fenceAndHold().then((_) => done = true));
      await _pump();
      expect(r.link.writes, hasLength(2));
      expect(done, isFalse);
      r.clock.advance(const Duration(milliseconds: 95)); // idle flush at 120
      expect(r.link.writes, hasLength(3));
      expect(r.link.last.withResponse, isTrue);
      await _pump();
      expect(done, isTrue);
    });

    test('a fence whose frame failed with nothing else outstanding stays '
        'pending until close', () async {
      final _Rig r = _Rig();
      r.lane.hold();
      Object? error;
      bool done = false;
      unawaited(
        r.lane.fenceAndHold().then(
          (_) => done = true,
          onError: (Object e) => error = e,
        ),
      );
      r.link.failNext = true;
      r.lane.release();
      expect(r.link.writes, hasLength(1));
      await _pump();
      r.clock.advance(const Duration(seconds: 5));
      await _pump();
      expect(r.link.writes, hasLength(1));
      expect(done, isFalse);
      expect(error, isNull);
      r.lane.close();
      await _pump();
      expect(error, isA<LinkClosedException>());
    });

    test('a closed writer fails frames without breaking the lane', () async {
      final _Rig r = _Rig();
      r.writer.close(LinkLossReason.lost);
      r.lane.submit(terminal: true);
      await _pump();
      expect(r.link.writes, isEmpty);
      expect(r.lane.framesWritten, 0);
      expect(r.delivered, isEmpty);
    });
  });
}
