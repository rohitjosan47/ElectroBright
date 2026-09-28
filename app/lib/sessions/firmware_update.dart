import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/ble/ble_link.dart';
import '../core/firmware/firmware_bundle.dart';
import '../core/protocol/eb/eb_ota.dart';
import '../core/util/scheduler.dart';
import '../drivers/electrobright/eb_session.dart';
import '../drivers/electrobright/eb_types.dart';
import 'connection_manager.dart';
import 'fixture_session.dart';

const GattRef otaControl = GattRef(EbOta.serviceUuid, EbOta.controlUuid);
const GattRef otaData = GattRef(EbOta.serviceUuid, EbOta.dataUuid);

/// Where a wireless update is.
enum UpdateStage {
  /// Connecting to the light and checking what it runs.
  preparing,

  /// Sending the image (resumes after a dropped link).
  sending,

  /// Everything arrived: the light checks the image and selects it.
  installing,

  /// The light restarts; waiting for it to come back.
  restarting,

  /// Back on the new firmware: waiting until it has confirmed itself.
  checking,

  done,
  failed,
  cancelled,

  /// The new firmware did not confirm itself: the light went back to its
  /// previous firmware.
  rolledBack;

  bool get finished => index >= done.index;
}

/// Why an update stopped (each is shown as a clear message).
enum UpdateProblem {
  /// The light could not be reached.
  notConnected,

  /// Its firmware has no wireless updates (before 3.8.0).
  unsupported,

  /// The light has newer firmware (never sent; also the light's DOWNGRADE).
  downgrade,

  /// The light already runs this version (the light's SAME_VERSION).
  sameVersion,

  /// The image bundled with the app failed its own check.
  badImage,

  /// BAD_SIZE: the image does not fit the light.
  tooBig,

  /// HASH_MISMATCH: the image arrived damaged.
  damaged,

  /// NOT_ELECTROBRIGHT: the light did not accept the image.
  notAccepted,

  /// FLASH_ERROR: the light could not write or select it.
  flash,

  /// BUSY: another transfer, a restart pending, or an update not yet
  /// confirmed.
  busy,

  /// BAD_REQUEST.
  badRequest,

  /// The transfer stopped and could not be resumed.
  stalled,

  /// The link dropped and the light did not come back in time.
  linkLost,

  /// The light stopped answering the update requests.
  noAnswer,

  /// The light did not come back after restarting.
  notBack,

  /// It came back with a version that is neither the old nor the new one.
  otherVersion,

  /// Another light is being updated (one at a time).
  anotherUpdate,
}

/// One update's state, for the UI.
@immutable
final class UpdateProgress {
  const UpdateProgress({
    required this.fixtureId,
    required this.stage,
    required this.to,
    this.from,
    this.reinstall = false,
    this.sent = 0,
    this.total = 0,
    this.timeLeft,
    this.reconnecting = false,
    this.problem,
  });

  final String fixtureId;
  final UpdateStage stage;

  /// The version the light ran before, once known.
  final FirmwareVersion? from;
  final FirmwareVersion to;
  final bool reinstall;

  /// Bytes the light confirmed, of [total].
  final int sent;
  final int total;

  /// Estimated time left of the transfer (null until measurable).
  final Duration? timeLeft;

  /// The link dropped mid-transfer; waiting to resume.
  final bool reconnecting;
  final UpdateProblem? problem;

  double get fraction => total == 0 ? 0 : sent / total;
  bool get running => !stage.finished;

  /// Stopping is possible (and safe: the light keeps its firmware). Once the
  /// image is complete the light installs it on its own.
  bool get cancellable =>
      stage == UpdateStage.preparing || stage == UpdateStage.sending;

  UpdateProgress copyWith({
    UpdateStage? stage,
    FirmwareVersion? from,
    int? sent,
    int? total,
    Duration? timeLeft,
    bool? reconnecting,
    UpdateProblem? problem,
  }) => UpdateProgress(
    fixtureId: fixtureId,
    stage: stage ?? this.stage,
    to: to,
    from: from ?? this.from,
    reinstall: reinstall,
    sent: sent ?? this.sent,
    total: total ?? this.total,
    timeLeft: timeLeft,
    reconnecting: reconnecting ?? this.reconnecting,
    problem: problem ?? this.problem,
  );

  @override
  bool operator ==(Object other) =>
      other is UpdateProgress &&
      other.fixtureId == fixtureId &&
      other.stage == stage &&
      other.from == from &&
      other.to == to &&
      other.reinstall == reinstall &&
      other.sent == sent &&
      other.total == total &&
      other.timeLeft == timeLeft &&
      other.reconnecting == reconnecting &&
      other.problem == problem;

  @override
  int get hashCode => Object.hash(
    fixtureId,
    stage,
    from,
    to,
    reinstall,
    sent,
    total,
    timeLeft,
    reconnecting,
    problem,
  );

  @override
  String toString() =>
      'UpdateProgress($fixtureId ${stage.name} $sent/$total'
      '${problem == null ? '' : ' ${problem!.name}'})';
}

/// The update engine's waits.
final class UpdateTiming {
  const UpdateTiming({
    this.connect = const Duration(seconds: 20),
    this.reply = const Duration(seconds: 3),
    this.beginAttempts = 3,
    this.ack = const Duration(seconds: 3),
    this.end = const Duration(seconds: 15),
    this.stallLimit = const Duration(seconds: 45),
    this.reconnect = const Duration(seconds: 30),
    this.maxResumes = 5,
    this.restart = const Duration(seconds: 60),
    this.confirm = const Duration(seconds: 18),
    this.abort = const Duration(seconds: 2),
  });

  /// For the light to be connected before the update starts.
  final Duration connect;

  /// For a reply to BEGIN, STATUS or ABORT.
  final Duration reply;
  final int beginAttempts;

  /// For the ACK of a window; then STATUS asks where the light is.
  final Duration ack;

  /// For END's reply (the light hashes and validates the whole image).
  final Duration end;

  /// How long the transfer may make no progress before giving up (longer
  /// than the light's own 15 s transfer timeout, after which it resumes).
  final Duration stallLimit;

  /// For the light to come back after the link dropped mid-transfer.
  final Duration reconnect;
  final int maxResumes;

  /// For the light to come back after END_OK (it restarts).
  final Duration restart;

  /// From END_OK until the new firmware has surely confirmed itself (its
  /// self-check ends 15 s after it starts; docs/protocol.md §10).
  final Duration confirm;

  /// For ABORTED after a cancel.
  final Duration abort;
}

/// Wireless firmware updates (docs/protocol.md §10), one light at a time.
///
/// While a light updates, its [FixtureSession] is marked updating (groups
/// skip it, its intents are refused) and the session's command and colour
/// lanes are paused; the update service shares the link's single writer.
/// After END_OK the light restarts; the engine waits for it to reconnect
/// (same device), checks the version and, once the new firmware's self-check
/// window has passed, DIAG's rollback flag and running slot.
final class FirmwareUpdates {
  FirmwareUpdates({
    required this._connections,
    required this._scheduler,
    this.timing = const UpdateTiming(),
    this.onRunning,
  });

  final ConnectionManager _connections;
  final Scheduler _scheduler;
  final UpdateTiming timing;

  /// Called with true when an update starts and false when it ends (the app
  /// keeps the screen awake meanwhile).
  final void Function(bool running)? onRunning;

  final Map<String, UpdateProgress> _last = <String, UpdateProgress>{};
  final StreamController<UpdateProgress> _changes =
      StreamController<UpdateProgress>.broadcast();
  _Run? _active;
  bool _disposed = false;

  /// The light being updated, if any.
  String? get activeId => _active?.fixtureId;

  /// The latest progress of [fixtureId]'s update (kept after it finished,
  /// until [clear]).
  UpdateProgress? progressOf(String fixtureId) => _last[fixtureId];
  Stream<UpdateProgress> get changes => _changes.stream;

  /// Whether [status] is a connected light whose firmware can take
  /// [bundled] over the air as an update (older, never a downgrade).
  static bool offers(FixtureStatus status, FirmwareVersion? bundled) {
    final EbFirmware? fw = status.view?.firmware;
    if (bundled == null || fw == null || !status.isConnected) return false;
    if (!fw.wirelessUpdates || status.updating) return false;
    final FirmwareVersion? v = FirmwareVersion.tryParse(fw.version.version);
    return v != null && v < bundled;
  }

  /// Updates [fixtureId] to [image] ([reinstall]: also when it already runs
  /// that version). Completes with the final progress; it never throws.
  Future<UpdateProgress> start(
    String fixtureId, {
    required FirmwareVersion version,
    required Future<FirmwareImage> Function() image,
    bool reinstall = false,
  }) async {
    final UpdateProgress first = UpdateProgress(
      fixtureId: fixtureId,
      stage: UpdateStage.preparing,
      to: version,
      reinstall: reinstall,
    );
    if (_active != null || _disposed) {
      final UpdateProgress busy = first.copyWith(
        stage: UpdateStage.failed,
        problem: UpdateProblem.anotherUpdate,
      );
      // Another light's update keeps its own progress.
      if (_active?.fixtureId != fixtureId) _emit(busy);
      return busy;
    }
    final _Run run = _Run(this, fixtureId, first);
    _active = run;
    onRunning?.call(true);
    _emit(first);
    try {
      return await run.execute(image);
    } finally {
      _active = null;
      onRunning?.call(false);
    }
  }

  /// Stops [fixtureId]'s update while that is safe ([UpdateProgress
  /// .cancellable]); the light keeps its firmware.
  void cancel(String fixtureId) {
    final _Run? run = _active;
    if (run == null || run.fixtureId != fixtureId) return;
    if (!run.progress.cancellable) return;
    run.requestCancel();
  }

  /// Forgets a finished update's result.
  void clear(String fixtureId) {
    final UpdateProgress? p = _last[fixtureId];
    if (p == null || p.running) return;
    _last.remove(fixtureId);
  }

  Future<void> dispose() async {
    _disposed = true;
    _active?.requestCancel(force: true);
    unawaited(_changes.close());
  }

  void _emit(UpdateProgress p) {
    _last[p.fixtureId] = p;
    if (!_changes.isClosed) _changes.add(p);
  }
}

/// Thrown inside a run to end it with [progress]'s outcome.
final class _Stop implements Exception {
  const _Stop(this.stage, [this.problem]);
  final UpdateStage stage;
  final UpdateProblem? problem;
}

/// The link of the session in use ended.
final class _LinkLost implements Exception {
  const _LinkLost();
}

/// One update from start to result.
final class _Run {
  _Run(this._owner, this.fixtureId, this.progress);

  final FirmwareUpdates _owner;
  final String fixtureId;
  UpdateProgress progress;
  bool _cancel = false;

  /// Set by dispose: every wait ends at once.
  bool _abandon = false;
  final List<void Function()> _wakers = <void Function()>[];

  Scheduler get _scheduler => _owner._scheduler;
  UpdateTiming get _t => _owner.timing;

  void requestCancel({bool force = false}) {
    _cancel = true;
    _abandon = _abandon || force;
    for (final void Function() w in List<void Function()>.of(_wakers)) {
      w();
    }
  }

  void _set(UpdateProgress p) {
    if (p == progress) return;
    progress = p;
    _owner._emit(p);
  }

  void _checkCancel() {
    if (_cancel) throw const _Stop(UpdateStage.cancelled);
  }

  Future<UpdateProgress> execute(
    Future<FirmwareImage> Function() loadImage,
  ) async {
    final FixtureSession? fs = _owner._connections.session(fixtureId);
    if (fs == null) {
      return _finish(
        const _Stop(UpdateStage.failed, UpdateProblem.notConnected),
      );
    }
    final Want want = _owner._connections.want(fixtureId, WantReason.update);
    EbSession? session;
    try {
      session = await _connected(fs, _t.connect);
      if (session == null) {
        throw _cancel
            ? const _Stop(UpdateStage.cancelled)
            : const _Stop(UpdateStage.failed, UpdateProblem.notConnected);
      }
      final EbFirmware fw = session.firmware!;
      final FirmwareVersion? installed = FirmwareVersion.tryParse(
        fw.version.version,
      );
      _set(progress.copyWith(from: installed));
      if (!fw.wirelessUpdates || installed == null) {
        throw const _Stop(UpdateStage.failed, UpdateProblem.unsupported);
      }
      if (progress.to < installed) {
        throw const _Stop(UpdateStage.failed, UpdateProblem.downgrade);
      }
      if (progress.to == installed && !progress.reinstall) {
        throw const _Stop(UpdateStage.failed, UpdateProblem.sameVersion);
      }
      final FirmwareImage image;
      try {
        image = await loadImage();
      } on Object {
        throw const _Stop(UpdateStage.failed, UpdateProblem.badImage);
      }
      if (image.version != progress.to) {
        throw const _Stop(UpdateStage.failed, UpdateProblem.badImage);
      }
      _checkCancel();
      // Where it runs from now: a light still on this slot afterwards went
      // back to it.
      final Map<String, int>? before = await session.diag();
      final int? slotBefore = before?['slot'];
      fs.setUpdating(on: true);
      _checkCancel();

      session = await _send(fs, session, image);
      final Duration installedAt = _scheduler.now;
      _set(progress.copyWith(stage: UpdateStage.restarting));
      return await _confirm(fs, session, installed, installedAt, slotBefore);
    } on _Stop catch (s) {
      // ABORT on the link in use (a resumed transfer has a new one).
      if (s.stage == UpdateStage.cancelled) await _abortOn(fs.session);
      return _finish(s);
    } finally {
      fs.session?.resumeLanes();
      session?.resumeLanes();
      fs.setUpdating(on: false);
      want.release();
    }
  }

  UpdateProgress _finish(_Stop s) {
    final UpdateProgress p = progress.copyWith(
      stage: s.stage,
      problem: s.problem,
      reconnecting: false,
    );
    _set(p);
    return p;
  }

  // ---- transfer ---------------------------------------------------------------

  /// Sends [image] until END_OK, resuming on a new link after a drop.
  /// Returns the session END_OK came on.
  Future<EbSession> _send(
    FixtureSession fs,
    EbSession first,
    FirmwareImage image,
  ) async {
    EbSession session = first;
    int resumes = 0;
    while (true) {
      final _Port port = _Port(session, this);
      try {
        session.pauseLanes();
        await _transfer(port, image);
        return session;
      } on _LinkLost {
        if (++resumes > _t.maxResumes) {
          throw const _Stop(UpdateStage.failed, UpdateProblem.linkLost);
        }
        _set(progress.copyWith(reconnecting: true, timeLeft: null));
        final EbSession? next = await _connected(
          fs,
          _t.reconnect,
          other: session,
        );
        _checkCancel();
        if (next == null) {
          throw const _Stop(UpdateStage.failed, UpdateProblem.linkLost);
        }
        session = next;
        _set(progress.copyWith(reconnecting: false));
      } finally {
        port.close();
      }
    }
  }

  Future<void> _transfer(_Port port, FirmwareImage image) async {
    final Uint8List begin = _beginRequest(image);
    int next = await _begin(port, begin);
    final int chunk = _chunkSize(port.session.mtu);
    _Rate rate = _Rate(_scheduler.now, next);
    _set(
      progress.copyWith(
        stage: UpdateStage.sending,
        sent: next,
        total: image.size,
      ),
    );
    Duration progressAt = _scheduler.now;
    int incompletes = 0;
    while (true) {
      while (next < image.size) {
        _checkCancel();
        final int end = min(
          image.size,
          (next ~/ EbOta.window + 1) * EbOta.window,
        );
        for (int at = next; at < end; at += chunk) {
          _checkCancel();
          await port.data(image.bytes, at, min(chunk, end - at));
        }
        final int before = next;
        final _Reply? r = await port.next(
          _t.ack,
          (_Reply r) => r.kind == EbOta.ack || r.kind == EbOta.error,
        );
        if (r == null) {
          // The window's last chunk (or its ACK) was lost: ask where it is.
          final _Reply? st = await _status(port);
          if (st == null) {
            if (_scheduler.now - progressAt > _t.stallLimit) {
              throw const _Stop(UpdateStage.failed, UpdateProblem.noAnswer);
            }
            continue;
          }
          if (st.a == EbOta.stateReceiving) {
            next = st.b;
          } else if (st.a == EbOta.stateIdle) {
            // The transfer stopped (timeout): resume where it got to.
            next = await _begin(port, begin);
            rate = _Rate(_scheduler.now, next);
          } else {
            throw const _Stop(UpdateStage.failed, UpdateProblem.busy);
          }
        } else if (r.kind == EbOta.ack) {
          next = r.a;
        } else if (r.a == EbOtaError.timeout.code) {
          next = await _begin(port, begin);
          rate = _Rate(_scheduler.now, next);
        } else {
          throw _Stop(UpdateStage.failed, _problemOf(r.a));
        }
        if (next > before) {
          progressAt = _scheduler.now;
        } else if (_scheduler.now - progressAt > _t.stallLimit) {
          throw const _Stop(UpdateStage.failed, UpdateProblem.stalled);
        }
        _set(
          progress.copyWith(
            sent: next,
            timeLeft: rate.left(_scheduler.now, next, image.size),
          ),
        );
      }
      // Everything arrived: the light checks and selects the image.
      _checkCancel();
      _set(progress.copyWith(stage: UpdateStage.installing, timeLeft: null));
      await port.control(const <int>[EbOta.end]);
      final _Reply? r = await port.next(
        _t.end,
        (_Reply r) => r.kind == EbOta.endOk || r.kind == EbOta.error,
      );
      if (r != null && r.kind == EbOta.endOk) return;
      if (r == null) {
        final _Reply? st = await _status(port);
        // END_OK was lost: it is restarting.
        if (st != null && st.a == EbOta.stateRestarting) return;
        if (st == null || st.a != EbOta.stateReceiving) {
          throw const _Stop(UpdateStage.failed, UpdateProblem.noAnswer);
        }
        next = st.b;
      } else if (r.a == EbOtaError.incomplete.code) {
        next = r.b;
      } else if (r.a == EbOtaError.timeout.code) {
        next = await _begin(port, begin);
      } else {
        throw _Stop(UpdateStage.failed, _problemOf(r.a));
      }
      if (++incompletes > 3) {
        throw const _Stop(UpdateStage.failed, UpdateProblem.stalled);
      }
      _set(progress.copyWith(stage: UpdateStage.sending, sent: next));
    }
  }

  /// BEGIN, retried (the notification subscription may not be live yet; a
  /// BEGIN of the same image answers with the offset reached). Returns where
  /// to send from.
  Future<int> _begin(_Port port, Uint8List request) async {
    for (int attempt = 0; attempt < _t.beginAttempts; attempt++) {
      _checkCancel();
      port.drain();
      await port.control(request);
      final _Reply? r = await port.next(
        _t.reply,
        (_Reply r) => r.kind == EbOta.beginOk || r.kind == EbOta.error,
      );
      if (r == null) continue;
      if (r.kind == EbOta.beginOk) return r.a;
      throw _Stop(UpdateStage.failed, _problemOf(r.a));
    }
    throw const _Stop(UpdateStage.failed, UpdateProblem.noAnswer);
  }

  /// STATE (state, next, size), or null. The light reporting TIMEOUT
  /// meanwhile reads as idle (the transfer stopped).
  Future<_Reply?> _status(_Port port) async {
    port.drain();
    await port.control(const <int>[EbOta.status]);
    final _Reply? r = await port.next(
      _t.reply,
      (_Reply r) => r.kind == EbOta.state,
    );
    return r?.kind == EbOta.error
        ? const _Reply(EbOta.state, EbOta.stateIdle)
        : r;
  }

  /// After a cancel: ABORT, so the light forgets the transfer at once.
  Future<void> _abortOn(EbSession? session) async {
    if (session == null || session.phase == EbPhase.closed || _abandon) return;
    final _Port port = _Port(session, this, ignoreCancel: true);
    try {
      port.drain();
      await port.control(const <int>[EbOta.abort]);
      await port.next(_t.abort, (_Reply r) => r.kind == EbOta.aborted);
    } on Object {
      // The link is gone: the light stops the transfer by itself.
    } finally {
      port.close();
    }
  }

  Uint8List _beginRequest(FirmwareImage image) {
    final ByteData b = ByteData(EbOta.beginLength)
      ..setUint8(0, EbOta.begin)
      ..setUint32(1, image.size, Endian.little);
    final Uint8List out = b.buffer.asUint8List();
    out.setAll(5, image.sha256);
    b
      ..setUint16(37, image.version.major, Endian.little)
      ..setUint16(39, image.version.minor, Endian.little)
      ..setUint16(41, image.version.patch, Endian.little)
      ..setUint8(43, progress.reinstall ? EbOta.flagReinstall : 0);
    return out;
  }

  /// DATA payload per write: the whole write fits MTU − 3.
  static int _chunkSize(int mtu) =>
      max(16, min(mtu - 3, 512) - EbOta.dataHeader);

  static UpdateProblem _problemOf(int code) =>
      switch (EbOtaError.fromCode(code)) {
        EbOtaError.badSize => UpdateProblem.tooBig,
        EbOtaError.hashMismatch => UpdateProblem.damaged,
        EbOtaError.notElectroBright => UpdateProblem.notAccepted,
        EbOtaError.downgrade => UpdateProblem.downgrade,
        EbOtaError.sameVersion => UpdateProblem.sameVersion,
        EbOtaError.flashError => UpdateProblem.flash,
        EbOtaError.busy => UpdateProblem.busy,
        EbOtaError.timeout => UpdateProblem.stalled,
        EbOtaError.incomplete => UpdateProblem.stalled,
        EbOtaError.badRequest || null => UpdateProblem.badRequest,
      };

  // ---- after END_OK -------------------------------------------------------------

  /// The light restarts into the new firmware, which confirms itself within
  /// its self-check window or goes back to the previous one.
  Future<UpdateProgress> _confirm(
    FixtureSession fs,
    EbSession old,
    FirmwareVersion from,
    Duration installedAt,
    int? slotBefore,
  ) async {
    EbSession? s = await _connected(fs, _t.restart, other: old);
    if (s == null) throw _abandonedOr(UpdateProblem.notBack);
    _set(progress.copyWith(stage: UpdateStage.checking));
    while (true) {
      final FirmwareVersion? v = FirmwareVersion.tryParse(
        s!.firmware!.version.version,
      );
      if (v != progress.to) {
        if (v == from) throw const _Stop(UpdateStage.rolledBack);
        throw const _Stop(UpdateStage.failed, UpdateProblem.otherVersion);
      }
      final Duration left = installedAt + _t.confirm - _scheduler.now;
      if (await _dropsWithin(s, left)) {
        // It restarted again: a failed self-check going back.
        s = await _connected(fs, _t.restart, other: s);
        if (s == null) throw _abandonedOr(UpdateProblem.notBack);
        continue;
      }
      final Map<String, int>? d = await s.diag();
      if (d != null &&
          (d['rb'] == 1 || (slotBefore != null && d['slot'] == slotBefore))) {
        throw const _Stop(UpdateStage.rolledBack);
      }
      return _finish(const _Stop(UpdateStage.done));
    }
  }

  _Stop _abandonedOr(UpdateProblem p) => _abandon
      ? const _Stop(UpdateStage.cancelled)
      : _Stop(UpdateStage.failed, p);

  /// Whether [s]'s link ends within [d].
  Future<bool> _dropsWithin(EbSession s, Duration d) async {
    if (s.phase == EbPhase.closed) return true;
    if (d <= Duration.zero) return false;
    final Completer<bool> done = Completer<bool>();
    final Cancelable timer = _scheduler.after(d, () {
      if (!done.isCompleted) done.complete(false);
    });
    unawaited(
      s.linkClosed.then((_) {
        if (!done.isCompleted) done.complete(true);
      }),
    );
    void wake() {
      if (!done.isCompleted) done.complete(false);
    }

    _wakers.add(wake);
    try {
      final bool dropped = await done.future;
      if (_abandon) throw const _Stop(UpdateStage.cancelled);
      return dropped;
    } finally {
      timer.cancel();
      _wakers.remove(wake);
    }
  }

  /// [fs]'s session once it is connected and identified (another than
  /// [other]), or null after [limit] or a cancel.
  Future<EbSession?> _connected(
    FixtureSession fs,
    Duration limit, {
    EbSession? other,
  }) async {
    EbSession? ready() {
      final EbSession? s = fs.session;
      if (s == null ||
          identical(s, other) ||
          s.phase == EbPhase.closed ||
          s.firmware == null ||
          !fs.status.isConnected) {
        return null;
      }
      return s;
    }

    final EbSession? now = ready();
    if (now != null) return now;
    final Completer<EbSession?> done = Completer<EbSession?>();
    final StreamSubscription<FixtureStatus> sub = fs.statuses.listen((_) {
      final EbSession? s = ready();
      if (s != null && !done.isCompleted) done.complete(s);
    });
    final Cancelable timer = _scheduler.after(limit, () {
      if (!done.isCompleted) done.complete(null);
    });
    void wake() {
      if (!done.isCompleted) done.complete(null);
    }

    _wakers.add(wake);
    try {
      return await done.future;
    } finally {
      timer.cancel();
      _wakers.remove(wake);
      unawaited(sub.cancel());
    }
  }
}

/// Transfer rate since a (re)start, for the time left.
final class _Rate {
  _Rate(this._at, this._from);
  final Duration _at;
  final int _from;

  Duration? left(Duration now, int next, int size) {
    final int bytes = next - _from;
    final int us = (now - _at).inMicroseconds;
    if (bytes < EbOta.window || us <= 0) return null;
    return Duration(microseconds: ((size - next) * us / bytes).round());
  }
}

/// A control notification: [kind] and up to three numbers (BEGIN_OK start
/// and window; ACK next; STATE state, next, size; ERROR code, next).
@immutable
final class _Reply {
  const _Reply(this.kind, [this.a = 0, this.b = 0, this.c = 0]);
  final int kind;
  final int a;
  final int b;
  final int c;

  static _Reply? parse(Uint8List d) {
    if (d.isEmpty) return null;
    final ByteData v = ByteData.sublistView(d);
    int u32(int at) => v.getUint32(at, Endian.little);
    return switch (d[0]) {
      EbOta.beginOk when d.length >= 7 => _Reply(
        EbOta.beginOk,
        u32(1),
        v.getUint16(5, Endian.little),
      ),
      EbOta.ack when d.length >= 5 => _Reply(EbOta.ack, u32(1)),
      EbOta.endOk => const _Reply(EbOta.endOk),
      EbOta.aborted => const _Reply(EbOta.aborted),
      EbOta.state when d.length >= 10 => _Reply(
        EbOta.state,
        d[1],
        u32(2),
        u32(6),
      ),
      EbOta.error when d.length >= 6 => _Reply(EbOta.error, d[1], u32(2)),
      _ => null,
    };
  }
}

/// The update service on one session's link: control writes and replies,
/// data writes. A closed link throws [_LinkLost]; a cancel wakes a wait.
final class _Port {
  _Port(this.session, this._run, {this._ignoreCancel = false}) {
    _sub = session
        .subscribeRaw(otaControl)
        .listen(_onNote, onError: (Object _) {});
    unawaited(session.linkClosed.then((_) => _wake()));
    _run._wakers.add(_wake);
  }

  final EbSession session;
  final _Run _run;
  final bool _ignoreCancel;
  late final StreamSubscription<Uint8List> _sub;
  final Queue<_Reply> _replies = Queue<_Reply>();
  Completer<void>? _waiter;

  bool get _closed => session.phase == EbPhase.closed;

  void _onNote(Uint8List b) {
    final _Reply? r = _Reply.parse(b);
    if (r == null) return;
    _replies.add(r);
    _wake();
  }

  void _wake() {
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void drain() => _replies.clear();

  /// The next reply [wanted] accepts (others are dropped), or null after
  /// [timeout]. An unsolicited ERROR:TIMEOUT is always returned.
  Future<_Reply?> next(Duration timeout, bool Function(_Reply r) wanted) async {
    final Duration deadline = _run._scheduler.now + timeout;
    while (true) {
      while (_replies.isNotEmpty) {
        final _Reply r = _replies.removeFirst();
        if (wanted(r) ||
            (r.kind == EbOta.error && r.a == EbOtaError.timeout.code)) {
          return r;
        }
      }
      if (!_ignoreCancel) _run._checkCancel();
      if (_closed) throw const _LinkLost();
      final Duration left = deadline - _run._scheduler.now;
      if (left <= Duration.zero) return null;
      final Completer<void> w = _waiter = Completer<void>();
      final Cancelable t = _run._scheduler.after(left, _wake);
      await w.future;
      t.cancel();
    }
  }

  Future<void> control(List<int> bytes) =>
      _write(otaControl, Uint8List.fromList(bytes), withResponse: true);

  Future<void> data(Uint8List image, int offset, int length) {
    final Uint8List w = Uint8List(EbOta.dataHeader + length);
    ByteData.sublistView(w).setUint32(0, offset, Endian.little);
    w.setAll(
      EbOta.dataHeader,
      Uint8List.sublistView(image, offset, offset + length),
    );
    return _write(otaData, w, withResponse: false);
  }

  Future<void> _write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) async {
    if (_closed) throw const _LinkLost();
    try {
      await session.writeRaw(ref, value, withResponse: withResponse);
    } on Object {
      if (_closed) throw const _LinkLost();
      // A refused write on a live link: the ACK / reply wait recovers.
    }
  }

  void close() {
    _run._wakers.remove(_wake);
    unawaited(_sub.cancel());
  }
}
