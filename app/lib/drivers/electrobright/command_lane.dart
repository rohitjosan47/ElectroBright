import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../core/ble/ble_link.dart';
import '../../core/ble/link_writer.dart';
import '../../core/protocol/eb/eb_command.dart';
import '../../core/protocol/eb/eb_reply.dart';
import '../../core/protocol/eb/reply_grammar.dart';
import '../../core/protocol/eb/text_chunker.dart';
import '../../core/util/scheduler.dart';
import 'eb_types.dart';
import 'stream_lane.dart';

/// Called synchronously when a command finishes, before any later reply line
/// is processed, so state effects apply in exact wire order.
typedef CommandDone = void Function(
  EbCommand command,
  int seq,
  EbResult result,
  List<EbReply> notes,
);

/// Ordered text commands with exact reply matching.
///
/// * At most one reply-bearing command is outstanding (the firmware's 1 KB
///   reply buffer drops old lines when full, which would shift matching).
///   Typed queries may be pipelined, but never alongside such a command.
/// * Queued commands with the same merge key collapse to the newest; merging
///   never crosses a barrier (presets, factory reset).
/// * Commands that need a fence first make the stream lane deliver the latest
///   colour reliably and hold it, then send `PING` and wait for its `OK`: the
///   firmware applies the mailbox frame at the start of every control pass,
///   so a command sent after that OK executes after the frame.
/// * On timeout: a line reset (discards any half-received command), one
///   resend for idempotent commands, and [onUnresponsive] after two timeouts
///   in a row.
final class CommandLane {
  CommandLane({
    required this._writer,
    required this._rx,
    required this._scheduler,
    required this._mtu,
    required this._stream,
    required this._isRedundant,
    required this._onDone,
    required this._onUnresponsive,
  });

  final LinkWriter _writer;
  final GattRef _rx;
  final Scheduler _scheduler;
  final int Function() _mtu;
  final StreamLane _stream;
  final bool Function(EbCommand command) _isRedundant;
  final CommandDone _onDone;
  final void Function() _onUnresponsive;

  static const int maxPipelinedQueries = 5;
  static const Duration storageGrace = Duration(milliseconds: 300);

  final Queue<_Job> _queue = Queue<_Job>();
  _Job? _active;
  final List<_Job> _queries = <_Job>[];
  bool _starting = false;
  bool _closed = false;
  int _consecutiveTimeouts = 0;

  int sent = 0;
  int timeouts = 0;
  int merged = 0;
  int skipped = 0;

  bool get isIdle =>
      _queue.isEmpty && _active == null && _queries.isEmpty && !_starting;

  /// Queues [command]; the future completes with the outcome. [attempts]
  /// overrides the per-attempt timeouts (default: the command timeout, plus
  /// one resend when idempotent).
  Future<EbResult> enqueue(
    EbCommand command, {
    required int seq,
    bool fence = false,
    bool atHead = false,
    List<Duration>? attempts,
  }) {
    if (_closed) return Future<EbResult>.value(EbResult.disconnected);
    final _Job job = _Job(
      command,
      seq,
      fence: fence || command.needsFence,
      attempts:
          attempts ??
          <Duration>[command.timeout, if (command.idempotent) command.timeout],
    );
    final String? key = command.mergeKey;
    if (key != null && !command.isBarrier && !atHead) {
      for (final _Job queued in _queue.toList().reversed) {
        if (queued.command.isBarrier) break;
        if (queued.command.mergeKey == key && !queued.fence && !job.fence) {
          _replace(queued, job);
          merged++;
          _pump();
          return job.done.future;
        }
      }
    }
    if (atHead) {
      _queue.addFirst(job);
    } else {
      _queue.addLast(job);
    }
    _pump();
    return job.done.future;
  }

  /// Offers a reply line; returns false if it belongs to no command.
  bool onReply(EbReply reply) {
    final _Job? active = _active;
    if (active != null && active.sent) {
      switch (matchReply(active.command.expect, reply)) {
        case ReplyMatch.success:
          _consecutiveTimeouts = 0;
          _finish(active, EbResult(EbOutcome.ok, reply: reply));
          return true;
        case ReplyMatch.failure:
          _consecutiveTimeouts = 0;
          _finish(active, _failure(reply));
          return true;
        case ReplyMatch.note:
          active.notes.add(reply);
          return true;
        case ReplyMatch.provisional:
          active.notes.add(reply);
          active.grace ??= _scheduler.after(storageGrace, () {
            _finish(active, _failure(reply));
          });
          return true;
        case ReplyMatch.none:
          break;
      }
    }
    for (final _Job q in _queries) {
      if (!q.sent) continue;
      final ReplyMatch m = matchReply(q.command.expect, reply);
      if (m == ReplyMatch.success) {
        _consecutiveTimeouts = 0;
        _finish(q, EbResult(EbOutcome.ok, reply: reply));
        return true;
      }
      if (m == ReplyMatch.failure) {
        _consecutiveTimeouts = 0;
        _finish(q, _failure(reply));
        return true;
      }
    }
    return false;
  }

  /// Fails everything outstanding; the link is gone.
  void close() {
    if (_closed) return;
    _closed = true;
    final List<_Job> all = <_Job>[?_active, ..._queries, ..._queue];
    _queue.clear();
    for (final _Job j in all) {
      _finish(j, EbResult.disconnected, pump: false);
    }
  }

  // ---- internals -------------------------------------------------------------------

  EbResult _failure(EbReply reply) => EbResult(
    EbOutcome.failed,
    code: reply is EbError ? reply.code : 'UNEXPECTED',
    reply: reply,
  );

  void _replace(_Job old, _Job fresh) {
    final List<_Job> items = _queue.toList();
    _queue
      ..clear()
      ..addAll(items.map((_Job j) => identical(j, old) ? fresh : j));
    _finish(old, EbResult.superseded, pump: false);
  }

  void _pump() {
    if (_closed || _starting || _active != null || _queue.isEmpty) return;
    final _Job job = _queue.first;
    if (job.command.isQuery && !job.fence) {
      if (_queries.length >= maxPipelinedQueries) return;
      _queue.removeFirst();
      _queries.add(job);
      unawaited(_transmit(job));
      _pump();
      return;
    }
    if (_queries.isNotEmpty) return; // wait: keeps reply matching exact
    _queue.removeFirst();
    if (!job.command.isBarrier && !job.fence && _isRedundant(job.command)) {
      skipped++;
      _finish(job, EbResult.skipped);
      return;
    }
    unawaited(_start(job));
  }

  Future<void> _start(_Job job) async {
    _starting = true;
    try {
      if (job.fence) {
        await _stream.fenceAndHold();
        job.holding = true;
        final _Job ping = _Job(
          const Ping(),
          -1,
          fence: false,
          attempts: <Duration>[const Ping().timeout],
        )..internal = true;
        // _starting stays true: nothing else may be sent until [job] is.
        _active = ping;
        await _transmit(ping);
        final EbResult pong = await ping.done.future;
        if (_closed) return;
        if (pong.outcome != EbOutcome.ok) {
          _starting = false;
          _finish(job, pong);
          return;
        }
      } else if (job.command.holdsStream) {
        _stream.hold();
        job.holding = true;
      }
      _active = job;
      _starting = false;
      await _transmit(job);
    } on LinkClosedException {
      _finish(job, EbResult.disconnected);
    } finally {
      _starting = false;
    }
  }

  /// Writes the command (chunked) and arms its timeout.
  Future<void> _transmit(_Job job) async {
    final List<Uint8List> chunks = chunkCommand(job.command.wire, _mtu());
    try {
      for (int i = 0; i < chunks.length; i++) {
        // Replies can only follow the final chunk's terminator; mark the job
        // before that write so a reply that races the write callback matches.
        if (i == chunks.length - 1) {
          job.sent = true;
          job.sentAt = _scheduler.now;
          job.timer = _scheduler.after(
            job.attempts[job.attempt],
            () => _onTimeout(job),
          );
        }
        await _writer.write(_rx, chunks[i], withResponse: true);
        if (job.done.isCompleted) return;
      }
      sent++;
    } on LinkClosedException {
      _finish(job, EbResult.disconnected);
    }
  }

  void _onTimeout(_Job job) {
    job.timer = null;
    if (job.done.isCompleted) return;
    timeouts++;
    _consecutiveTimeouts++;
    // Discard whatever part of the command the light may be holding.
    unawaited(
      _writer
          .write(_rx, lineResetWrite, withResponse: true)
          .catchError((Object _) {}),
    );
    if (job.attempt + 1 < job.attempts.length) {
      job.attempt++;
      job.sent = false;
      unawaited(_transmit(job));
    } else {
      _finish(job, EbResult.timedOut);
    }
    if (_consecutiveTimeouts >= 2) _onUnresponsive();
  }

  void _finish(_Job job, EbResult result, {bool pump = true}) {
    if (job.done.isCompleted) return;
    job.timer?.cancel();
    job.grace?.cancel();
    if (identical(_active, job)) _active = null;
    _queries.remove(job);
    if (job.holding) {
      job.holding = false;
      _stream.release();
    }
    if (!job.internal) _onDone(job.command, job.seq, result, job.notes);
    job.done.complete(result);
    // An internal fence PING completes inside _start, which continues itself.
    if (pump && !job.internal) _pump();
  }
}

final class _Job {
  _Job(this.command, this.seq, {required this.fence, required this.attempts});

  final EbCommand command;
  final int seq;
  final bool fence;
  final List<Duration> attempts;
  final Completer<EbResult> done = Completer<EbResult>();
  final List<EbReply> notes = <EbReply>[];
  int attempt = 0;
  bool sent = false;
  bool holding = false;
  bool internal = false;
  Duration? sentAt;
  Cancelable? timer;
  Cancelable? grace;
}
