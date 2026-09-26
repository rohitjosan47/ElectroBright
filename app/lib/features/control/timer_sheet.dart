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
String stepLabel(Duration d) => d.inHours >= 1
    ? '${d.inMinutes % 60 == 0 ? d.inHours : (d.inMinutes / 60).toStringAsFixed(1)} h'
    : d.inMinutes >= 1
    ? '${d.inMinutes} min'
    : '${d.inSeconds} s';

/// A running countdown ("4:59", "1:02:03").
String countdown(Duration d) {
  final int s = d.inSeconds.clamp(0, 86400);
  final String mm = '${(s ~/ 60) % 60}'.padLeft(s >= 3600 ? 2 : 1, '0');
  final String ss = '${s % 60}'.padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:$mm:$ss' : '$mm:$ss';
}

/// Time left on the light's sleep timer (null = none), ticking each second
/// while it can be seen (not under a full-screen route).
class TimerCountdown extends ConsumerStatefulWidget {
  const TimerCountdown({
    required this.fixtureId,
    required this.builder,
    super.key,
  });
  final String fixtureId;
  final Widget Function(BuildContext context, Duration? left) builder;

  @override
  ConsumerState<TimerCountdown> createState() => _TimerCountdownState();
}

class _TimerCountdownState extends ConsumerState<TimerCountdown> {
  ProviderSubscription<Duration?>? _deadline;
  Timer? _tick;
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
      _tick?.cancel();
      _tick = null;
    } else {
      _arm(_deadline?.read());
    }
  }

  @override
  void didUpdateWidget(TimerCountdown old) {
    super.didUpdateWidget(old);
    if (old.fixtureId != widget.fixtureId) _listen();
  }

  @override
  void dispose() {
    _deadline?.close();
    _tick?.cancel();
    super.dispose();
  }

  void _listen() {
    _deadline?.close();
    _deadline = ref.listenManual(
      _deadlineOf(widget.fixtureId),
      (_, Duration? deadline) => _arm(deadline),
      fireImmediately: true,
    );
  }

  /// Ticks each second while the light's timer runs, stops once it is over.
  void _arm(Duration? deadline) {
    final Duration now = ref.read(servicesProvider).scheduler.now;
    if (deadline == null || deadline <= now || !_shown) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      _arm(_deadline?.read());
    });
  }

  @override
  Widget build(BuildContext context) {
    final Duration? deadline = ref.watch(_deadlineOf(widget.fixtureId));
    final Duration now = ref.watch(servicesProvider).scheduler.now;
    final Duration? left = deadline == null ? null : deadline - now;
    return widget.builder(
      context,
      left == null || left <= Duration.zero ? null : left,
    );
  }

  static ProviderListenable<Duration?> _deadlineOf(String fixtureId) =>
      fixtureStatusProvider(fixtureId)
          .select((FixtureStatus s) => s.state?.timerDeadline);
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
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext ctx) => ToneScope(
    tone: ToneScope.of(context),
    child: _TimerSheet(fixtureId: fixtureId, session: session),
  ),
);

class _TimerSheet extends ConsumerStatefulWidget {
  const _TimerSheet({required this.fixtureId, required this.session});
  final String fixtureId;
  final FixtureSession session;

  @override
  ConsumerState<_TimerSheet> createState() => _TimerSheetState();
}

class _TimerSheetState extends ConsumerState<_TimerSheet> {
  int _index = 4; // 10 min

  Future<void> _set(int seconds) async {
    final AppLocalizations l = AppLocalizations.of(context);
    final TimerSpanNotifier span = ref.read(
      timerSpanProvider(widget.fixtureId).notifier,
    );
    final Duration deadline =
        ref.read(servicesProvider).scheduler.now + Duration(seconds: seconds);
    final EbResult r = await widget.session.setTimer(seconds);
    if (!mounted) return;
    if (r.isSuccess) {
      if (seconds == 0) {
        span.cancelled();
      } else {
        span.started(Duration(seconds: seconds), deadline);
      }
      Navigator.of(context).pop();
    } else {
      showGlassToast(
        context,
        r.outcome == EbOutcome.disconnected ? l.errorOffline : l.errorGeneric,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final TimerSpan? span = ref.watch(timerSpanProvider(widget.fixtureId));
    final Duration? deadline = ref.watch(
      fixtureStatusProvider(widget.fixtureId)
          .select((FixtureStatus s) => s.state?.timerDeadline),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          0,
          Space.gutter,
          Space.gutter,
        ),
        child: TimerCountdown(
          fixtureId: widget.fixtureId,
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
                        ? stepLabel
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
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    return TimerCountdown(
      fixtureId: fixtureId,
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
          if (left != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(
                l.timerOff(countdown(left)),
                key: const ValueKey<String>('timer-left'),
                style: TextStyle(
                  color: fg.withValues(alpha: 0.75),
                  fontSize: 13,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
