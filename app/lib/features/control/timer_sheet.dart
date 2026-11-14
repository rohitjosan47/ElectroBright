import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../design/components/aura_add_button.dart';
import '../../app/providers.dart';
import '../../bootstrap/service_registry.dart';
import '../../design/components/glass_controls.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../core/color/light_tone.dart';
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

  /// The deadline being counted down, kept so the light reporting its timer
  /// done (deadline cleared) a moment before the countdown hits 0 still
  /// counts as running out, not as a cancel.
  Duration? _lastDeadline;

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
      // Ran out while counting down on screen: the light is switching off
      // now, so the phone confirms it like the power button does. Not on a
      // cancel with time left or when reopened long after it ended.
      final Duration? ended = deadline ?? _lastDeadline;
      if (_ticking &&
          _shown &&
          ended != null &&
          (now - ended).abs() < const Duration(seconds: 2)) {
        HapticsScope.of(context).play(HapticEvent.powerOff);
      }
      _lastDeadline = null;
      _stopTicking();
      return;
    }
    _lastDeadline = deadline;
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
}) {
  final NavigatorState nav = Navigator.of(context);
  return nav.push(
    _BlurredSheetRoute<void>(
      barrierLabel: MaterialLocalizations.of(context).scrimLabel,
      isScrollControlled: true,
      // Own drag handle (below), drawn above the sheet's heavy blur.
      showDragHandle: false,
      // No dark dim: the screen behind is softly blurred instead.
      modalBarrierColor: Colors.transparent,
      builder: (BuildContext ctx) => _LiveTone(
        outer: context,
        child: Stack(
          children: <Widget>[
            // Heavy blur only where the sheet covers the screen (on top of
            // the soft blur everywhere), so nothing behind it distracts.
            Positioned.fill(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // Fully opaque from the bottom up to the Start button, then
            // fading into the translucent upper part (both modes).
            Positioned.fill(
              child: IgnorePointer(
                child: Builder(
                  builder: (BuildContext c) {
                    final Color solid =
                        Theme.of(c).brightness == Brightness.dark
                        ? const Color(0xFF08090B)
                        : const Color(0xFFFFFFFF);
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: <Color>[
                            solid.withValues(alpha: 0),
                            solid.withValues(alpha: 0),
                            solid,
                            solid,
                          ],
                          stops: const <double>[0, 0.55, 0.76, 1],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            // Hairline along the rounded top edge, so the sheet separates
            // from the background in both modes.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TopHairline(
                    Theme.of(ctx).brightness == Brightness.dark
                        ? const Color(0x2EFFFFFF)
                        : const Color(0x1F000000),
                  ),
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                _TimerSheet(
                  deadline: deadline,
                  spanKey: spanKey,
                  onStart: onStart,
                  onCancel: onCancel,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Passes the control screen's light palette into the sheet, and keeps it
/// matching the current light/dark theme: after a theme switch it rebuilds
/// until the screen's palette has caught up, showing a neutral palette for
/// that frame instead of a stale one.
class _LiveTone extends StatefulWidget {
  const _LiveTone({required this.outer, required this.child});

  final BuildContext outer;
  final Widget child;

  @override
  State<_LiveTone> createState() => _LiveToneState();
}

class _LiveToneState extends State<_LiveTone> {
  int _retries = 0; // bounded, so a mismatch can never spin forever

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    LightTone tone = widget.outer.mounted
        ? ToneScope.of(widget.outer)
        : LightTone.neutral(dark: dark);
    if (tone.dark != dark) {
      tone = LightTone.neutral(dark: dark);
      if (_retries++ < 60) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
    } else {
      _retries = 0;
    }
    return ToneScope(tone: tone, child: widget.child);
  }
}

/// A hairline along a sheet's top edge and its 28 pt rounded corners.
class _TopHairline extends CustomPainter {
  const _TopHairline(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double r = 28;
    final Path edge = Path()
      ..moveTo(0.25, r)
      ..arcToPoint(const Offset(r, 0.25), radius: const Radius.circular(r))
      ..lineTo(size.width - r, 0.25)
      ..arcToPoint(
        Offset(size.width - 0.25, r),
        radius: const Radius.circular(r),
      );
    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_TopHairline o) => o.color != color;
}

/// A bottom sheet whose backdrop blurs the screen behind it (under the
/// sheet), easing in and out with the sheet's own open, close and drag.
class _BlurredSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _BlurredSheetRoute({
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.barrierLabel,
    super.modalBarrierColor,
    super.showDragHandle,
  });

  // The sheet's colour follows the current theme live, so switching
  // light/dark while the sheet is open repaints it correctly.
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final ThemeData theme = Theme.of(context);
    // Translucent over the blur: 78% white (light), 95% near-black (dark).
    final Color fill = theme.brightness == Brightness.dark
        ? const Color(0xF208090B)
        : const Color(0xC7FFFFFF);
    return Theme(
      data: theme.copyWith(
        bottomSheetTheme: theme.bottomSheetTheme.copyWith(
          backgroundColor: fill,
          modalBackgroundColor: fill,
        ),
      ),
      child: super.buildPage(context, animation, secondaryAnimation),
    );
  }

  @override
  Widget buildModalBarrier() => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      IgnorePointer(
        child: AnimatedBuilder(
          animation: animation!,
          builder: (BuildContext context, Widget? child) {
            // Reaches full blur in the first 40% of the slide.
            final double t = const Interval(
              0,
              0.4,
              curve: Curves.easeOut,
            ).transform(animation!.value.clamp(0.0, 1.0));
            if (t == 0) return const SizedBox.expand();
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10 * t, sigmaY: 10 * t),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
      super.buildModalBarrier(),
    ],
  );
}

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
                AuraButton(
                  key: const ValueKey<String>('timer-start'),
                  onPressed: () =>
                      unawaited(_set(timerSteps[_index].inSeconds)),
                  child: Text(l.timerStart),
                )
              else
                AuraButton(
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
