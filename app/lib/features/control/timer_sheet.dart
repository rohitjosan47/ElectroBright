import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../app/providers.dart';
import '../../bootstrap/service_registry.dart';
import '../../design/components/glass_controls.dart';
import '../../design/haptics/haptics.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';

/// Sleep-timer steps (the firmware allows up to 24 h).
const List<Duration> timerSteps = <Duration>[
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(minutes: 20),
  Duration(minutes: 30),
  Duration(minutes: 45),
  Duration(hours: 1),
  Duration(minutes: 90),
  Duration(hours: 2),
  Duration(hours: 3),
  Duration(hours: 4),
  Duration(hours: 6),
  Duration(hours: 8),
  Duration(hours: 12),
  Duration(hours: 24),
];

/// A step for the dial ("30 s", "5 min", "1.5 h").
String stepLabel(AppLocalizations l, Duration d) => d.inHours >= 1
    ? l.timerStepHours(
        d.inMinutes % 60 == 0
            ? '${d.inHours}'
            : (d.inMinutes / 60).toStringAsFixed(1),
      )
    : d.inMinutes >= 1
    ? l.timerStepMinutes(d.inMinutes)
    : l.timerStepSeconds(d.inSeconds);

/// A running countdown ("4:59", "1:02:03").
String countdown(Duration d) {
  final int s = d.inSeconds.clamp(0, 86400);
  final String mm = '${(s ~/ 60) % 60}'.padLeft(s >= 3600 ? 2 : 1, '0');
  final String ss = '${s % 60}'.padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:$mm:$ss' : '$mm:$ss';
}

/// One clock for every countdown shown: they change on the same tick.
abstract final class _CountdownClock {
  static final Set<VoidCallback> _listeners = <VoidCallback>{};
  static Timer? _timer;

  static void add(VoidCallback listener) {
    _listeners.add(listener);
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      for (final VoidCallback l in _listeners.toList()) {
        l();
      }
    });
  }

  static void remove(VoidCallback listener) {
    _listeners.remove(listener);
    if (_listeners.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
  }
}

/// A light's sleep-timer deadline (scheduler time; null = none).
final ProviderFamily<Duration?, String> timerDeadlineProvider =
    Provider.family<Duration?, String>(
      (Ref ref, String fixtureId) => ref.watch(
        fixtureStatusProvider(fixtureId)
            .select((FixtureStatus s) => s.state?.timerDeadline),
      ),
    );

/// Time left until [deadline] (null = none), ticking each second while it
/// can be seen (not under a full-screen route).
class TimerCountdown extends ConsumerStatefulWidget {
  const TimerCountdown({
    required this.deadline,
    required this.builder,
    super.key,
  });

  /// A light's ([timerDeadlineProvider]) or the group's deadline.
  final ProviderListenable<Duration?> deadline;
  final Widget Function(BuildContext context, Duration? left) builder;

  @override
  ConsumerState<TimerCountdown> createState() => _TimerCountdownState();
}

class _TimerCountdownState extends ConsumerState<TimerCountdown> {
  ProviderSubscription<Duration?>? _deadline;
  bool _ticking = false;
  bool _shown = true;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covered by a full-screen route it stops; shown again, it reads the
    // time left at once (the text is computed from the deadline).
    final bool shown = TickerMode.valuesOf(context).enabled;
    if (shown == _shown) return;
    _shown = shown;
    if (!shown) {
      _stopTicking();
    } else {
      _arm(_deadline?.read());
    }
  }

  @override
  void didUpdateWidget(TimerCountdown old) {
    super.didUpdateWidget(old);
    if (old.deadline != widget.deadline) _listen();
  }

  @override
  void dispose() {
    _deadline?.close();
    _stopTicking();
    super.dispose();
  }

  void _listen() {
    _deadline?.close();
    _deadline = ref.listenManual(
      widget.deadline,
      (_, Duration? deadline) => _arm(deadline),
      fireImmediately: true,
    );
  }

  /// Ticks each second while the light's timer runs, stops once it is over.
  void _arm(Duration? deadline) {
    final Duration now = ref.read(servicesProvider).scheduler.now;
    if (deadline == null || deadline <= now || !_shown) {
      _stopTicking();
      return;
    }
    if (_ticking) return;
    _ticking = true;
    _CountdownClock.add(_onTick);
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
    _arm(_deadline?.read());
  }

  void _stopTicking() {
    if (!_ticking) return;
    _ticking = false;
    _CountdownClock.remove(_onTick);
  }

  @override
  Widget build(BuildContext context) {
    final Duration? deadline = ref.watch(widget.deadline);
    final Duration now = ref.watch(servicesProvider).scheduler.now;
    final Duration? left = deadline == null ? null : deadline - now;
    return widget.builder(
      context,
      left == null || left <= Duration.zero ? null : left,
    );
  }
}

/// The duration a light's running timer was started with from this app.
/// Kept beside its deadline, so a timer started or restarted elsewhere (whose
/// deadline differs) is not measured against it.
@immutable
final class TimerSpan {
  const TimerSpan({required this.total, required this.deadline});
  final Duration total;
  final Duration deadline;

  /// Deadlines re-read from the light drift by the link latency and its
  /// whole-second rounding.
  static const Duration tolerance = Duration(seconds: 5);

  bool matches(Duration deadline) =>
      (deadline - this.deadline).abs() <= tolerance;
}

/// The [TimerSpan] of each light's timer (lives past the sheet).
final NotifierProviderFamily<TimerSpanNotifier, TimerSpan?, String>
timerSpanProvider =
    NotifierProvider.family<TimerSpanNotifier, TimerSpan?, String>(
      TimerSpanNotifier.new,
    );

final class TimerSpanNotifier extends Notifier<TimerSpan?> {
  TimerSpanNotifier(this.fixtureId);
  final String fixtureId;

  @override
  TimerSpan? build() => null;

  void started(Duration total, Duration deadline) =>
      state = TimerSpan(total: total, deadline: deadline);

  void cancelled() => state = null;
}

/// The duration the running timer (deadline [deadline], [left] to go) is
/// measured against: what this app started it with, else the smallest step
/// that holds it (the steps are all any ElectroBright app offers).
Duration timerTotal(TimerSpan? span, Duration deadline, Duration left) {
  if (span != null && span.matches(deadline) && span.total >= left) {
    return span.total;
  }
  return timerSteps.firstWhere(
    (Duration s) => s >= left,
    orElse: () => timerSteps.last,
  );
}

/// Picks and starts (or cancels) the light's sleep timer.
Future<void> showTimerSheet(
  BuildContext context, {
  required String fixtureId,
  required FixtureSession session,
}) {
  final AppLocalizations l = AppLocalizations.of(context);
  Future<String?> send(int seconds) async {
    final EbResult r = await session.setTimer(seconds);
    if (r.isSuccess) return null;
    return r.outcome == EbOutcome.disconnected
        ? l.errorOffline
        : l.errorGeneric;
  }

  return showSleepTimerSheet(
    context,
    deadline: timerDeadlineProvider(fixtureId),
    spanKey: fixtureId,
    onStart: (Duration d) => send(d.inSeconds),
    onCancel: () => send(0),
  );
}

/// The sleep-timer sheet: a dial to choose a duration ([onStart]), or the
/// running countdown to [deadline] with [onCancel]. Both answer null when
/// done (the sheet closes) or the message to show. [spanKey]: whose
/// [TimerSpan] the dial measures against.
Future<void> showSleepTimerSheet(
  BuildContext context, {
  required ProviderListenable<Duration?> deadline,
  required String spanKey,
  required Future<String?> Function(Duration d) onStart,
  required Future<String?> Function() onCancel,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext ctx) => ToneScope(
    tone: ToneScope.of(context),
    child: _TimerSheet(
      deadline: deadline,
      spanKey: spanKey,
      onStart: onStart,
      onCancel: onCancel,
    ),
  ),
);

class _TimerSheet extends ConsumerStatefulWidget {
  const _TimerSheet({
    required this.deadline,
    required this.spanKey,
    required this.onStart,
    required this.onCancel,
  });
  final ProviderListenable<Duration?> deadline;
  final String spanKey;
  final Future<String?> Function(Duration d) onStart;
  final Future<String?> Function() onCancel;

  @override
  ConsumerState<_TimerSheet> createState() => _TimerSheetState();
}

class _TimerSheetState extends ConsumerState<_TimerSheet> {
  int _index = 4; // 10 min

  Future<void> _set(int seconds) async {
    final TimerSpanNotifier span = ref.read(
      timerSpanProvider(widget.spanKey).notifier,
    );
    final Duration deadline =
        ref.read(servicesProvider).scheduler.now + Duration(seconds: seconds);
    final String? error = seconds == 0
        ? await widget.onCancel()
        : await widget.onStart(Duration(seconds: seconds));
    if (!mounted) return;
    if (error == null) {
      if (seconds == 0) {
        span.cancelled();
      } else {
        span.started(Duration(seconds: seconds), deadline);
      }
      Navigator.of(context).pop();
    } else {
      showGlassToast(context, error, icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final TimerSpan? span = ref.watch(timerSpanProvider(widget.spanKey));
    final Duration? deadline = ref.watch(widget.deadline);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          0,
          Space.gutter,
          Space.gutter,
        ),
        child: TimerCountdown(
          deadline: widget.deadline,
          builder: (BuildContext context, Duration? left) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l.timer, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Space.m),
              Center(
                child: SizedBox.square(
                  dimension: 240,
                  // Running: the light can only cancel its timer, not retime
                  // it, so the dial is a read-only countdown.
                  child: TimerDial(
                    steps: timerSteps,
                    index: _index,
                    label: left == null
                        ? (Duration d) => stepLabel(l, d)
                        : (_) => l.timerOff(countdown(left)),
                    progress: left == null || deadline == null
                        ? null
                        : (left.inMilliseconds /
                                  timerTotal(
                                    span,
                                    deadline,
                                    left,
                                  ).inMilliseconds)
                              .clamp(0.0, 1.0),
                    onChanged: (int i) => setState(() => _index = i),
                  ),
                ),
              ),
              const SizedBox(height: Space.m),
              if (left == null)
                FilledButton(
                  key: const ValueKey<String>('timer-start'),
                  onPressed: () =>
                      unawaited(_set(timerSteps[_index].inSeconds)),
                  child: Text(l.timerStart),
                )
              else
                FilledButton(
                  key: const ValueKey<String>('timer-cancel'),
                  onPressed: () => unawaited(_set(0)),
                  child: Text(l.timerCancel),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Timer and sound buttons under the orb.
class ControlToolbar extends ConsumerWidget {
  const ControlToolbar({
    required this.fixtureId,
    required this.session,
    required this.soundOn,
    required this.sleeping,
    required this.enabled,
    this.onSettings,
    super.key,
  });

  final String fixtureId;
  final FixtureSession? session;
  final bool soundOn;
  final bool sleeping;
  final bool enabled;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final FixtureSession? s = enabled ? session : null;
    return TimerCountdown(
      deadline: timerDeadlineProvider(fixtureId),
      builder: (BuildContext context, Duration? left) => Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              GlassIconButton(
                key: const ValueKey<String>('timer-button'),
                icon: Icons.timer_outlined,
                label: l.timer,
                active: left != null,
                // A sleeping light has nothing to time.
                onPressed: s == null || sleeping
                    ? null
                    : () => unawaited(
                        showTimerSheet(
                          context,
                          fixtureId: fixtureId,
                          session: s,
                        ),
                      ),
              ),
              const SizedBox(width: Space.l),
              GlassIconButton(
                key: const ValueKey<String>('sound-button'),
                icon: soundOn
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                label: soundOn ? l.soundOn : l.soundOff,
                active: soundOn,
                haptic: HapticEvent.selection,
                onPressed: s == null
                    ? null
                    : () => unawaited(s.setSound(on: !soundOn)),
              ),
              if (onSettings != null) ...<Widget>[
                const SizedBox(width: Space.l),
                GlassIconButton(
                  key: const ValueKey<String>('settings-button'),
                  icon: Icons.tune_rounded,
                  label: l.lightSettings,
                  onPressed: onSettings,
                ),
              ],
            ],
          ),
          if (left != null) TimerCaption(l.timerOff(countdown(left))),
        ],
      ),
    );
  }
}

/// The line under a timer button ("Off in 4:59", "Timers differ").
class TimerCaption extends StatelessWidget {
  const TimerCaption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Text(
        text,
        key: const ValueKey<String>('timer-left'),
        style: TextStyle(
          color: fg.withValues(alpha: 0.75),
          fontSize: 13,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
