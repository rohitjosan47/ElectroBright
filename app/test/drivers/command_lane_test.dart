import 'dart:async';
import 'dart:typed_data';

import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/ble/link_writer.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_command.dart';
import 'package:electrobright/core/protocol/eb/eb_reply.dart';
import 'package:electrobright/core/protocol/eb/text_chunker.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/command_lane.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/drivers/electrobright/stream_lane.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 10]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const GattRef _rx = GattRef('svc', 'rx');

final class _Write {
  _Write(this.value, this.withResponse);
  final Uint8List value;
  final bool withResponse;
  final Completer<void> done = Completer<void>();
}

/// Records writes; acknowledges them at once unless [manual].
final class _FakeLink implements BleLink {
  bool manual = false;
  final List<_Write> writes = <_Write>[];

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
    final _Write w = _Write(value, withResponse);
    writes.add(w);
    if (!manual) w.done.complete();
    return w.done.future;
  }
}

typedef _Done = ({
  EbCommand command,
  int seq,
  EbResult result,
  List<EbReply> notes,
});

final class _Rig {
  _Rig() {
    writer = LinkWriter(link);
    stream = StreamLane(
      writer: writer,
      rx: _rx,
      scheduler: clock,
      desired: () => (color: ChannelColor.rgbw(1, 2, 3, 4), brightness: 50),
      onDelivered: (_) {},
    );
    lane = CommandLane(
      writer: writer,
      rx: _rx,
      scheduler: clock,
      mtu: () => mtu,
      stream: stream,
      isRedundant: (EbCommand c) => redundant(c),
      onDone: (EbCommand c, int seq, EbResult r, List<EbReply> notes) =>
          done.add((command: c, seq: seq, result: r, notes: notes)),
      onUnresponsive: () => unresponsive++,
    );
  }

  final ManualScheduler clock = ManualScheduler();
  final _FakeLink link = _FakeLink();
  late final LinkWriter writer;
  late final StreamLane stream;
  late final CommandLane lane;
  int mtu = 185;
  bool Function(EbCommand c) redundant = (_) => false;
  final List<_Done> done = <_Done>[];
  int unresponsive = 0;
  int _seq = 0;

  /// Enqueues [c] and records its outcome in [results] under its wire text.
  final Map<String, EbResult> results = <String, EbResult>{};
  Future<EbResult> send(
    EbCommand c, {
    bool fence = false,
    bool atHead = false,
    List<Duration>? attempts,
  }) {
    final Future<EbResult> f = lane.enqueue(
      c,
      seq: _seq++,
      fence: fence,
      atHead: atHead,
      attempts: attempts,
    );
    unawaited(f.then((EbResult r) => results[c.wire] = r));
    return f;
  }

  /// Everything written, as lines: text commands (chunks joined), `FRAME`
  /// for colour frames, `RESET` for the line reset.
  List<String> get lines {
    final List<String> out = <String>[];
    final StringBuffer pending = StringBuffer();
    for (final _Write w in link.writes) {
      if (w.value.isNotEmpty && w.value[0] == 0xAA) {
        out.add('FRAME');
        continue;
      }
      if (w.value.length == 2 && w.value[0] == 0x15 && w.value[1] == 0x0A) {
        out.add('RESET');
        continue;
      }
      for (final int b in w.value) {
        if (b == 0x0A) {
          out.add(pending.toString());
          pending.clear();
        } else {
          pending.writeCharCode(b);
        }
      }
    }
    return out;
  }

  Future<void> run(Duration d) async {
    await _pump();
    clock.advance(d);
    await _pump();
  }
}

const EbVersion _version = EbVersion('3.8.2', 3, 8, 2);

void main() {
  test('a command is written with response and completes on its OK; onDone '
      'reports it with its sequence number', () async {
    final _Rig r = _Rig();
    expect(r.lane.isIdle, isTrue);
    final Future<EbResult> f = r.lane.enqueue(SetMode(3), seq: 41);
    expect(r.lane.isIdle, isFalse);
    await _pump();
    expect(r.lines, <String>['MODE:3']);
    expect(r.link.writes.every((_Write w) => w.withResponse), isTrue);
    expect(r.lane.onReply(const EbOk()), isTrue);
    final EbResult result = await f;
    expect(result.outcome, EbOutcome.ok);
    expect(result.reply, isA<EbOk>());
    expect(r.done.single.command.wire, 'MODE:3');
    expect(r.done.single.seq, 41);
    expect(r.done.single.result.outcome, EbOutcome.ok);
    expect(r.lane.sent, 1);
    expect(r.lane.isIdle, isTrue);
  });

  test('one reply-bearing command at a time, sent in order, each answered '
      'by the next reply', () async {
    final _Rig r = _Rig();
    unawaited(r.send(SetMode(2)));
    unawaited(r.send(const SetPower(on: false)));
    unawaited(r.send(const SetSound(on: true)));
    await _pump();
    expect(r.lines, <String>['MODE:2']);
    r.lane.onReply(const EbOk());
    await _pump();
    expect(r.lines, <String>['MODE:2', 'SLEEP']);
    r.lane.onReply(const EbError(EbError.format));
    await _pump();
    expect(r.lines, <String>['MODE:2', 'SLEEP', 'SOUND_ON']);
    r.lane.onReply(const EbOk());
    await _pump();
    expect(r.results['MODE:2']!.outcome, EbOutcome.ok);
    expect(r.results['SLEEP']!.outcome, EbOutcome.failed);
    expect(r.results['SLEEP']!.code, EbError.format);
    expect(r.results['SOUND_ON']!.outcome, EbOutcome.ok);
    expect(r.done.map((_Done d) => d.command.wire), <String>[
      'MODE:2',
      'SLEEP',
      'SOUND_ON',
    ]);
  });

  test('replies that belong to no command are refused and change '
      'nothing', () async {
    final _Rig r = _Rig();
    expect(r.lane.onReply(const EbOk()), isFalse, reason: 'nothing sent');
    unawaited(r.send(SetMode(1)));
    await _pump();
    expect(r.lane.onReply(const EbInfo('EB-C3-RGBW-V1')), isFalse);
    expect(
      r.lane.onReply(const EbError(EbError.storage)),
      isFalse,
      reason: 'a plain OK command never gets STORAGE',
    );
    expect(r.results, isEmpty);
    expect(r.lane.onReply(const EbOk()), isTrue);
  });

  test('an error fails the command with its code; UNKNOWN_CMD fails any '
      'command', () async {
    final _Rig r = _Rig();
    unawaited(r.send(SetMode(1)));
    unawaited(r.send(const Identify()));
    await _pump();
    r.lane.onReply(const EbError(EbError.modeInvalid));
    await _pump();
    r.lane.onReply(const EbError(EbError.unknownCommand));
    await _pump();
    expect(r.results['MODE:1']!.outcome, EbOutcome.failed);
    expect(r.results['MODE:1']!.code, EbError.modeInvalid);
    expect(r.results['MODE:1']!.reply, isA<EbError>());
    expect(r.results['IDENTIFY']!.code, EbError.unknownCommand);
    expect(r.results['IDENTIFY']!.isSuccess, isFalse);
  });

  test('long commands are chunked to the MTU; a reply matches once the '
      'final chunk is being written', () async {
    final _Rig r = _Rig()..mtu = 23;
    r.link.manual = true;
    final Future<EbResult> f = r.send(SetModeFrequency(13, 10));
    await _pump();
    expect(r.link.writes, hasLength(1));
    expect(r.link.writes[0].value, hasLength(20));
    expect(r.lane.onReply(const EbOk()), isFalse, reason: 'not all sent');
    r.link.writes[0].done.complete();
    await _pump();
    expect(r.link.writes, hasLength(2));
    expect(r.link.writes[1].value, <int>[0x0A]);
    // The reply may race the final write's callback.
    expect(r.lane.onReply(const EbOk()), isTrue);
    expect((await f).outcome, EbOutcome.ok);
    r.link.writes[1].done.complete();
    await _pump();
    expect(r.lines, <String>['MODE_FREQUENCY:13,10']);
  });

  group('queries', () {
    test('up to five are pipelined; a sixth waits for a free slot; each '
        'reply resolves the query it answers', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const InfoQuery()));
      unawaited(r.send(const VersionQuery()));
      unawaited(r.send(const CapsQuery()));
      unawaited(r.send(const StatusQuery()));
      unawaited(r.send(const ModeSettingsQuery()));
      unawaited(r.send(const PresetListQuery()));
      await _pump();
      expect(r.lines, <String>[
        'INFO',
        'VERSION',
        'CAPS',
        'STATUS',
        'MODE_SETTINGS',
      ]);
      expect(r.lane.onReply(_version), isTrue);
      await _pump();
      expect(r.results.keys, <String>['VERSION']);
      expect(r.results['VERSION']!.reply, same(_version));
      expect(r.lines.last, 'PRESET_LIST');
      expect(
        r.lane.onReply(const EbCaps(<String, String>{'PROTOCOL': '1'})),
        isTrue,
      );
      expect(r.lane.onReply(const EbInfo('EB-C3-RGBW-V1')), isTrue);
      await _pump();
      expect(r.results.keys, containsAll(<String>['VERSION', 'CAPS', 'INFO']));
      expect(r.results.containsKey('STATUS'), isFalse);
      expect(
        r.lane.onReply(const EbOk()),
        isFalse,
        reason: 'no query wants OK',
      );
    });

    test('a query error fails the oldest outstanding query', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const InfoQuery()));
      unawaited(r.send(const DiagQuery()));
      await _pump();
      expect(r.lane.onReply(const EbError(EbError.setupNeeded)), isTrue);
      await _pump();
      expect(r.results['INFO']!.code, EbError.setupNeeded);
      expect(r.results.containsKey('DIAG'), isFalse);
    });

    test('a command waits for outstanding queries; queries behind it wait '
        'for its reply', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const InfoQuery()));
      unawaited(r.send(SetMode(1)));
      unawaited(r.send(const VersionQuery()));
      await _pump();
      expect(r.lines, <String>['INFO']);
      r.lane.onReply(const EbInfo('EB-C3-RGBW-V1'));
      await _pump();
      expect(r.lines, <String>['INFO', 'MODE:1']);
      r.lane.onReply(const EbOk());
      await _pump();
      expect(r.lines, <String>['INFO', 'MODE:1', 'VERSION']);
    });
  });

  group('merging and ordering', () {
    test('queued changes to one setting collapse to the newest, which keeps '
        'the oldest one\'s place', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const SetPower(on: true))); // sent: never merged
      unawaited(r.send(SetMode(2)));
      unawaited(r.send(const SetSound(on: true)));
      unawaited(r.send(SetMode(3)));
      unawaited(r.send(SetMode(4)));
      await _pump();
      expect(r.lane.merged, 2);
      expect(r.results['MODE:2']!.outcome, EbOutcome.superseded);
      expect(r.results['MODE:3']!.outcome, EbOutcome.superseded);
      expect(r.results['MODE:2']!.isSuccess, isTrue);
      expect(
        r.done
            .where((_Done d) => d.result.outcome == EbOutcome.superseded)
            .map((_Done d) => d.command.wire),
        <String>['MODE:2', 'MODE:3'],
      );
      for (int i = 0; i < 3; i++) {
        r.lane.onReply(const EbOk());
        await _pump();
      }
      expect(r.lines, <String>['WAKE', 'MODE:4', 'SOUND_ON']);
    });

    test('merging never crosses a barrier', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const SetPower(on: true)));
      unawaited(r.send(SetMode(2)));
      unawaited(r.send(PresetDelete(1)));
      unawaited(r.send(SetMode(3)));
      await _pump();
      expect(r.lane.merged, 0);
      for (int i = 0; i < 4; i++) {
        r.lane.onReply(const EbOk());
        await _pump();
      }
      expect(r.lines, <String>['WAKE', 'MODE:2', 'PRESET_DELETE:1', 'MODE:3']);
    });

    test('atHead jumps the queue and does not merge', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const SetPower(on: true)));
      unawaited(r.send(SetMode(2)));
      unawaited(r.send(const SetSound(on: false)));
      unawaited(r.send(SetMode(5), atHead: true));
      await _pump();
      expect(r.lane.merged, 0);
      for (int i = 0; i < 4; i++) {
        r.lane.onReply(const EbOk());
        await _pump();
      }
      expect(r.lines, <String>['WAKE', 'MODE:5', 'MODE:2', 'SOUND_OFF']);
    });

    test('a fenced job never merges and is never merged into', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const SetPower(on: true)));
      unawaited(r.send(SetMode(2), fence: true));
      unawaited(r.send(SetMode(3)));
      await _pump();
      expect(r.lane.merged, 0);
    });

    test('a redundant command is skipped unsent; barriers, fenced commands '
        'and queries are never checked', () async {
      final _Rig r = _Rig()..redundant = (_) => true;
      final EbResult skipped = await r.send(const SetPower(on: false));
      expect(skipped.outcome, EbOutcome.skipped);
      expect(r.lane.skipped, 1);
      expect(r.done.single.result.outcome, EbOutcome.skipped);
      expect(r.link.writes, isEmpty);
      unawaited(r.send(PresetDelete(0)));
      await _pump();
      expect(r.lines, <String>['PRESET_DELETE:0']);
      r.lane.onReply(const EbOk());
      unawaited(r.send(const InfoQuery()));
      await _pump();
      expect(r.lines.last, 'INFO');
      r.lane.onReply(const EbInfo('x'));
      unawaited(r.send(SetMode(1), fence: true));
      await _pump();
      expect(r.lines.last, 'PING');
      expect(r.lane.skipped, 1);
    });
  });

  group('timeouts', () {
    test('an idempotent command: line reset and one resend, then timed out; '
        'two timeouts in a row report the light unresponsive', () async {
      final _Rig r = _Rig();
      unawaited(r.send(SetMode(1)));
      await r.run(const Duration(milliseconds: 1499));
      expect(r.lines, <String>['MODE:1']);
      await r.run(const Duration(milliseconds: 1));
      expect(r.lines, <String>['MODE:1', 'RESET', 'MODE:1']);
      expect(r.link.writes[1].value, <int>[0x15, 0x0A]);
      expect(r.link.writes[1].withResponse, isTrue);
      expect(r.lane.timeouts, 1);
      expect(r.unresponsive, 0);
      expect(r.results, isEmpty);
      await r.run(const Duration(milliseconds: 1500));
      expect(r.lines, <String>['MODE:1', 'RESET', 'MODE:1', 'RESET']);
      expect(r.results['MODE:1']!.outcome, EbOutcome.timedOut);
      expect(r.lane.timeouts, 2);
      expect(r.unresponsive, 1);
      expect(r.lane.isIdle, isTrue);
    });

    test('a reply to the resend succeeds and resets the timeout '
        'streak', () async {
      final _Rig r = _Rig();
      unawaited(r.send(SetMode(1)));
      await r.run(const Duration(milliseconds: 1500));
      expect(r.lane.onReply(const EbOk()), isTrue);
      await _pump();
      expect(r.results['MODE:1']!.outcome, EbOutcome.ok);
      unawaited(r.send(SetTimer(60)));
      await r.run(const Duration(milliseconds: 1500));
      expect(r.results['TIMER:60']!.outcome, EbOutcome.timedOut);
      expect(r.unresponsive, 0, reason: 'streak was reset by the OK');
    });

    test('a non-idempotent command is never resent', () async {
      final _Rig r = _Rig();
      unawaited(r.send(SetTimer(60)));
      await r.run(const Duration(milliseconds: 1500));
      expect(r.lines, <String>['TIMER:60', 'RESET']);
      expect(r.results['TIMER:60']!.outcome, EbOutcome.timedOut);
      expect(r.unresponsive, 0);
      unawaited(r.send(const FactoryReset()));
      await _pump();
      // The fence PING goes first (stream idle); it times out on its own.
      await r.run(const Duration(milliseconds: 1500));
      expect(r.results['FACTORY_RESET']!.outcome, EbOutcome.timedOut);
      expect(r.lines.where((String l) => l == 'FACTORY_RESET'), isEmpty);
      expect(r.unresponsive, 1);
    });

    test('attempts overrides the per-attempt timeouts', () async {
      final _Rig r = _Rig();
      unawaited(
        r.send(
          SetMode(2),
          attempts: const <Duration>[
            Duration(milliseconds: 100),
            Duration(milliseconds: 200),
            Duration(milliseconds: 300),
          ],
        ),
      );
      await r.run(const Duration(milliseconds: 100));
      expect(r.lane.timeouts, 1);
      await r.run(const Duration(milliseconds: 199));
      expect(r.lane.timeouts, 1);
      await r.run(const Duration(milliseconds: 1));
      expect(r.lane.timeouts, 2);
      await r.run(const Duration(milliseconds: 300));
      expect(r.lane.timeouts, 3);
      expect(r.results['MODE:2']!.outcome, EbOutcome.timedOut);
      expect(r.lines.where((String l) => l == 'MODE:2'), hasLength(3));
    });
  });

  group('storage replies', () {
    test('STORAGE before OK is a note for SOUND', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const SetSound(on: true)));
      await _pump();
      expect(r.lane.onReply(const EbError(EbError.storage)), isTrue);
      await _pump();
      expect(r.results, isEmpty);
      expect(r.lane.onReply(const EbOk()), isTrue);
      await _pump();
      expect(r.results['SOUND_ON']!.outcome, EbOutcome.ok);
      expect(r.done.single.notes.single, isA<EbError>());
    });

    test('STORAGE for a preset write is provisional: an OK within the grace '
        'wins, otherwise it fails', () async {
      final _Rig r = _Rig();
      unawaited(r.send(PresetDelete(2)));
      await _pump();
      expect(r.lane.onReply(const EbError(EbError.storage)), isTrue);
      await r.run(const Duration(milliseconds: 299));
      expect(r.results, isEmpty);
      r.lane.onReply(const EbOk());
      await _pump();
      expect(r.results['PRESET_DELETE:2']!.outcome, EbOutcome.ok);
      expect(r.done.last.notes, hasLength(1));
      // No late failure from the grace timer.
      await r.run(const Duration(seconds: 1));
      expect(r.done, hasLength(1));

      unawaited(r.send(PresetDelete(3)));
      await _pump();
      r.lane.onReply(const EbError(EbError.storage));
      await r.run(CommandLane.storageGrace);
      expect(r.results['PRESET_DELETE:3']!.outcome, EbOutcome.failed);
      expect(r.results['PRESET_DELETE:3']!.code, EbError.storage);
    });
  });

  group('fences and stream holds', () {
    test('a fenced command sends PING first, then the command; colour '
        'frames wait until it is answered', () async {
      final _Rig r = _Rig();
      unawaited(r.send(PresetSave(0)));
      await _pump();
      expect(r.lines, <String>['PING']);
      unawaited(r.send(const InfoQuery()));
      r.stream.submit();
      await _pump();
      expect(r.lines, <String>['PING'], reason: 'lane and stream held');
      expect(r.lane.onReply(const EbOk()), isTrue);
      await _pump();
      expect(r.lines, <String>['PING', 'PRESET_SAVE:0']);
      expect(r.done, isEmpty, reason: 'the fence PING is internal');
      r.lane.onReply(const EbOk());
      await _pump();
      expect(r.results['PRESET_SAVE:0']!.outcome, EbOutcome.ok);
      expect(r.done.single.command.wire, 'PRESET_SAVE:0');
      expect(r.lines, <String>['PING', 'PRESET_SAVE:0', 'FRAME', 'INFO']);
    });

    test('with an unfenced colour outstanding the fence writes it reliably '
        'before the PING', () async {
      final _Rig r = _Rig();
      r.stream.submit();
      await r.run(const Duration(milliseconds: 30));
      unawaited(r.send(SetMode(4), fence: true));
      await _pump();
      expect(r.lines, <String>['FRAME', 'FRAME', 'PING']);
      expect(r.link.writes[0].withResponse, isFalse);
      expect(r.link.writes[1].withResponse, isTrue);
      r.lane.onReply(const EbOk());
      await _pump();
      expect(r.lines.last, 'MODE:4');
    });

    test('a failed fence PING fails the command unsent and releases the '
        'stream', () async {
      final _Rig r = _Rig();
      unawaited(r.send(PresetLoad(1)));
      await _pump();
      expect(r.lines, <String>['PING']);
      r.lane.onReply(const EbError(EbError.format));
      await _pump();
      expect(r.results['PRESET_LOAD:1']!.outcome, EbOutcome.failed);
      expect(r.results['PRESET_LOAD:1']!.code, EbError.format);
      r.stream.submit();
      expect(r.lines.last, 'FRAME');
    });

    test('a command that holds the stream blocks frames until it is '
        'answered', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const SetType(ChannelLayout.rgb)));
      await _pump();
      expect(r.lines, <String>['SET_TYPE:RGB'], reason: 'no fence');
      r.stream.submit();
      await _pump();
      expect(r.lines, <String>['SET_TYPE:RGB']);
      r.lane.onReply(const EbOk());
      await _pump();
      expect(r.lines, <String>['SET_TYPE:RGB', 'FRAME']);
    });

    test('a fenced command whose stream lane is closed ends '
        'disconnected', () async {
      final _Rig r = _Rig();
      r.stream.close();
      final EbResult result = await r.send(PresetSave(2));
      expect(result.outcome, EbOutcome.disconnected);
      expect(r.link.writes, isEmpty);
      expect(r.lane.isIdle, isTrue);
    });
  });

  group('pause', () {
    test('while paused nothing new is sent; a sent command still gets its '
        'reply; resuming sends the queue', () async {
      final _Rig r = _Rig();
      unawaited(r.send(SetMode(1)));
      await _pump();
      r.lane.paused = true;
      expect(r.lane.paused, isTrue);
      unawaited(r.send(SetMode(2), atHead: true));
      unawaited(r.send(const InfoQuery()));
      expect(r.lane.onReply(const EbOk()), isTrue);
      await r.run(const Duration(seconds: 5));
      expect(r.results['MODE:1']!.outcome, EbOutcome.ok);
      expect(r.lines, <String>['MODE:1']);
      expect(r.lane.isIdle, isFalse);
      r.lane.paused = true; // no-op
      r.lane.paused = false;
      await _pump();
      expect(r.lines, <String>['MODE:1', 'MODE:2']);
      r.lane.onReply(const EbOk());
      await _pump();
      expect(r.lines.last, 'INFO');
    });

    test('queued commands do not time out while paused', () async {
      final _Rig r = _Rig();
      r.lane.paused = true;
      unawaited(r.send(SetMode(3)));
      await r.run(const Duration(minutes: 1));
      expect(r.results, isEmpty);
      expect(r.lane.timeouts, 0);
    });
  });

  group('close', () {
    test('fails the active command, outstanding queries and the queue; '
        'nothing is sent afterwards', () async {
      final _Rig r = _Rig();
      unawaited(r.send(const InfoQuery()));
      unawaited(r.send(const VersionQuery()));
      unawaited(r.send(SetMode(1)));
      unawaited(r.send(const SetSound(on: true)));
      await _pump();
      r.lane.close();
      await _pump();
      expect(r.results, hasLength(4));
      expect(
        r.results.values.every(
          (EbResult x) => x.outcome == EbOutcome.disconnected,
        ),
        isTrue,
      );
      expect(r.done, hasLength(4));
      expect(r.lane.isIdle, isTrue);
      final int written = r.link.writes.length;
      await r.run(const Duration(seconds: 10));
      expect(r.link.writes, hasLength(written), reason: 'timers cancelled');
      final EbResult late = await r.lane.enqueue(SetMode(9), seq: 99);
      expect(late.outcome, EbOutcome.disconnected);
      expect(r.done, hasLength(4), reason: 'no onDone after close');
      expect(r.lane.onReply(const EbOk()), isFalse);
      r.lane.close(); // idempotent
    });

    test('a write on a closed link ends the command disconnected', () async {
      final _Rig r = _Rig();
      r.writer.close(LinkLossReason.lost);
      final EbResult result = await r.send(SetMode(1));
      expect(result.outcome, EbOutcome.disconnected);
      expect(r.done.single.result.outcome, EbOutcome.disconnected);
      expect(r.link.writes, isEmpty);
    });

    test('closing while a fenced command waits for its PING fails the '
        'command', () async {
      final _Rig r = _Rig();
      unawaited(r.send(PresetSave(0)));
      await _pump();
      expect(r.lines, <String>['PING']);
      r.lane.close();
      await _pump();
      expect(r.results['PRESET_SAVE:0']?.outcome, EbOutcome.disconnected);
      expect(r.done.single.command.wire, 'PRESET_SAVE:0');
    });

    test('the session teardown order (writer, stream, lane) while the fence '
        'PING is being written ends the fenced command disconnected', () async {
      final _Rig r = _Rig();
      r.link.manual = true;
      unawaited(r.send(PresetLoad(2)));
      await _pump();
      expect(r.lines, <String>['PING']);
      // The link drops before the PING's write is confirmed.
      r.writer.close(LinkLossReason.lost);
      r.stream.close();
      r.lane.close();
      await _pump();
      expect(r.results['PRESET_LOAD:2']?.outcome, EbOutcome.disconnected);
      expect(r.done.single.result.outcome, EbOutcome.disconnected);
      expect(r.lane.isIdle, isTrue);
    });

    test('closing while a fenced command waits for the stream\'s fence frame '
        'fails it and releases the stream', () async {
      final _Rig r = _Rig();
      r.link.manual = true;
      r.stream.submit();
      await _pump();
      r.link.writes.single.done.complete();
      await _pump();
      r.clock.advance(const Duration(milliseconds: 30));
      unawaited(r.send(FactoryReset()));
      await _pump();
      // The reliable fence frame is in flight; no PING yet.
      expect(r.lines, <String>['FRAME', 'FRAME']);
      r.lane.close();
      await _pump();
      expect(r.results['FACTORY_RESET']?.outcome, EbOutcome.disconnected);
      // The fence frame lands after all: the hold it took is given back.
      r.link.writes.last.done.complete();
      await _pump();
      expect(r.stream.isIdle, isTrue);
      expect(r.lane.isIdle, isTrue);
    });

    test('fenced commands at every stage end disconnected when the link drops: '
        'awaiting the reply, waiting for PING, queued', () async {
      final _Rig r = _Rig();
      unawaited(r.send(PresetSave(0)));
      await _pump();
      r.lane.onReply(const EbOk()); // PING answered
      await _pump();
      expect(r.lines, <String>['PING', 'PRESET_SAVE:0']);
      unawaited(r.send(PresetLoad(1)));
      unawaited(r.send(SetMode(3), fence: true));
      await _pump();
      r.writer.close(LinkLossReason.lost);
      r.stream.close();
      r.lane.close();
      await _pump();
      expect(r.results['PRESET_SAVE:0']?.outcome, EbOutcome.disconnected);
      expect(r.results['PRESET_LOAD:1']?.outcome, EbOutcome.disconnected);
      expect(r.results['MODE:3']?.outcome, EbOutcome.disconnected);
      expect(r.done, hasLength(3));
    });

    test('a write refused on a live link before the last chunk ends the '
        'command (WRITE_FAILED); the next one goes', () async {
      final _Rig r = _Rig();
      r.mtu = 23; // 20-byte chunks: MODE_FREQUENCY:12,10 takes two
      r.link.manual = true;
      final Future<EbResult> f = r.send(SetModeFrequency(12, 10));
      unawaited(r.send(SetMode(5)));
      await _pump();
      expect(r.link.writes, hasLength(1));
      r.link.writes.first.done.completeError(StateError('refused'));
      await _pump();
      final EbResult result = await f;
      expect(result.outcome, EbOutcome.failed);
      expect(result.code, EbResult.writeFailed.code);
      expect(r.done.first.result.code, 'WRITE_FAILED');
      // A line reset first (the light drops the half line), then the next
      // command: not stuck.
      expect(r.link.writes, hasLength(2));
      expect(r.link.writes.last.value, lineResetWrite);
      r.link.writes.last.done.complete();
      await _pump();
      expect(r.link.writes, hasLength(3));
      expect(String.fromCharCodes(r.link.writes.last.value), 'MODE:5\n');
    });

    test('a fence frame refused three times on a live link fails the fenced '
        'command (WRITE_FAILED) and frees the lane', () async {
      final _Rig r = _Rig();
      r.link.manual = true;
      r.stream.submit();
      await _pump();
      r.link.writes.single.done.complete();
      await _pump();
      r.clock.advance(const Duration(milliseconds: 30));
      final Future<EbResult> f = r.send(PresetSave(1));
      unawaited(r.send(SetMode(6)));
      for (int i = 0; i < StreamLane.fenceAttempts; i++) {
        await _pump();
        expect(r.link.writes.last.withResponse, isTrue);
        r.link.writes.last.done.completeError(StateError('refused'));
        await _pump();
        r.clock.advance(const Duration(milliseconds: 30));
      }
      final EbResult result = await f;
      expect(result.code, 'WRITE_FAILED');
      expect(r.lines.where((String l) => l == 'PING'), isEmpty);
      await _pump();
      expect(r.lines.last, 'MODE:6', reason: 'the lane goes on');
    });
  });
}
