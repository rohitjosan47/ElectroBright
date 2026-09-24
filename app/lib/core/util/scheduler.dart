import 'dart:async';

/// A cancellable one-shot timer.
abstract interface class Cancelable {
  bool get isActive;
  void cancel();
}

/// Monotonic time and one-shot timers. Everything time-dependent in the
/// protocol stack goes through this, so tests run on virtual time
/// ([ManualScheduler]) and the app on real time ([SystemScheduler]).
abstract interface class Scheduler {
  Duration get now;
  Cancelable after(Duration delay, void Function() callback);
}

final class SystemScheduler implements Scheduler {
  /// [elapsed]: the time source (default: a monotonic stopwatch). Widget
  /// tests pass one that follows their fake timers.
  SystemScheduler({Duration Function()? elapsed})
    : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedFn;

  final Duration Function() _elapsed;

  @override
  Duration get now => _elapsed();

  @override
  Cancelable after(Duration delay, void Function() callback) =>
      _TimerHandle(Timer(delay, callback));
}

extension on Stopwatch {
  Duration Function() get elapsedFn =>
      () => elapsed;
}

final class _TimerHandle implements Cancelable {
  _TimerHandle(this._timer);
  final Timer _timer;
  @override
  bool get isActive => _timer.isActive;
  @override
  void cancel() => _timer.cancel();
}

/// Virtual time for tests: nothing fires until [advance] (or [runDue]).
final class ManualScheduler implements Scheduler {
  Duration _now = Duration.zero;
  final List<_ManualTask> _tasks = <_ManualTask>[];
  int _nextId = 0;

  @override
  Duration get now => _now;

  @override
  Cancelable after(Duration delay, void Function() callback) {
    final _ManualTask task = _ManualTask(
      _now + (delay.isNegative ? Duration.zero : delay),
      _nextId++,
      callback,
    );
    _tasks.add(task);
    return task;
  }

  /// Earliest pending deadline, or null.
  Duration? get nextDue {
    _tasks.removeWhere((_ManualTask t) => !t.isActive);
    if (_tasks.isEmpty) return null;
    return _tasks
        .map((_ManualTask t) => t.due)
        .reduce((Duration a, Duration b) => a < b ? a : b);
  }

  /// Advances time by [delta], firing due tasks in deadline order (tasks
  /// scheduled by callbacks fire too if they fall inside the window).
  void advance(Duration delta) {
    final Duration end = _now + delta;
    while (true) {
      final _ManualTask? next = _earliestDueBy(end);
      if (next == null) break;
      _now = next.due;
      next.fire();
    }
    _now = end;
  }

  /// Fires tasks that are due now, without moving time.
  void runDue() => advance(Duration.zero);

  _ManualTask? _earliestDueBy(Duration end) {
    _ManualTask? best;
    for (final _ManualTask t in _tasks) {
      if (!t.isActive || t.due > end) continue;
      if (best == null ||
          t.due < best.due ||
          (t.due == best.due && t.id < best.id)) {
        best = t;
      }
    }
    if (best != null) _tasks.remove(best);
    return best;
  }
}

final class _ManualTask implements Cancelable {
  _ManualTask(this.due, this.id, this._callback);
  final Duration due;
  final int id;
  void Function()? _callback;

  @override
  bool get isActive => _callback != null;

  @override
  void cancel() => _callback = null;

  void fire() {
    final void Function()? cb = _callback;
    _callback = null;
    cb?.call();
  }
}
