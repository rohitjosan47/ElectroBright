import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';

import '../../core/color/light_tone.dart';
import '../glass/glass_surface.dart';
import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';
import '../tokens/tokens.dart';
import '../tone/tone_scope.dart';

/// A horizontal glass slider. The value lives in local state while the finger
/// is down (the parent is told on every move but never has to rebuild this
/// widget), repaints go through a listenable, and detents fire haptics.
/// Values from the parent after release glide there on a spring.
///
/// * [divisions]: snap steps (null = continuous; haptic ticks every 10 %).
/// * [track]: gradient painted in the track (white, CCT, channel, hue...).
class GlassSlider extends StatefulWidget {
  const GlassSlider({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
    this.track,
    this.fill,
    this.height = 44,
    this.leading,
    this.trailing,
    this.trailingBuilder,
    this.valueText,
    this.enabled = true,
    super.key,
  }) : assert(trailing == null || trailingBuilder == null);

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// Colours painted along the whole track (gradient sliders).
  final List<Color>? track;

  /// Colour of the filled part (pill sliders); defaults to the tone accent.
  final Color? fill;
  final double height;
  final Widget? leading;
  final Widget? trailing;

  /// Trailing widget that follows the shown value (finger, spring). Rebuilt
  /// only when [valueText] of the value changes, e.g. per whole percent.
  final Widget Function(double value)? trailingBuilder;
  final String semanticLabel;
  final String Function(double value)? valueText;
  final bool enabled;

  @override
  State<GlassSlider> createState() => _GlassSliderState();
}

class _GlassSliderState extends State<GlassSlider>
    with SingleTickerProviderStateMixin {
  late final ValueNotifier<double> _v = ValueNotifier<double>(widget.value);

  /// [_v] as text: what semantics and [GlassSlider.trailingBuilder] show.
  late final ValueNotifier<String> _shown = ValueNotifier<String>(
    _text(widget.value),
  );
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => _v.value = _spring.value);
  bool _dragging = false;
  int _lastDetent = -1;

  /// The edge (-1 min, 1 max) whose haptic already played; cleared once the
  /// value leaves it by [_edgeRearm], so a jittering finger ticks once.
  int _edge = 0;
  static const double _edgeRearm = 0.02;

  /// Where [_v] is (or is heading): the parent's value is only followed when
  /// it differs.
  late double _goal;

  @override
  void initState() {
    super.initState();
    _goal = widget.value;
    _v.addListener(() => _shown.value = _text(_v.value));
  }

  @override
  void didUpdateWidget(GlassSlider old) {
    super.didUpdateWidget(old);
    // External updates never move the control under the finger.
    if (_dragging || widget.value == _goal) return;
    _goal = widget.value;
    if (Motion.reduced(context)) {
      _spring.stop();
      _v.value = _goal;
      return;
    }
    final double target = _goal;
    final double velocity = _spring.isAnimating ? _spring.velocity : 0;
    _spring.value = _v.value;
    unawaited(
      _spring
          .animateWith(
            SpringSimulation(Motion.smooth, _v.value, target, velocity),
          )
          // Settle exactly on the value (the spring stops within tolerance).
          .then((_) => _v.value = target),
    );
  }

  @override
  void dispose() {
    _spring.dispose();
    _shown.dispose();
    _v.dispose();
    super.dispose();
  }

  /// The user takes over: stop gliding, the finger sets the value.
  void _set(double v) {
    _spring.stop();
    _goal = v;
    _v.value = v;
  }

  double _snap(double v) {
    final int? d = widget.divisions;
    final double c = v.clamp(widget.min, widget.max);
    if (d == null || d == 0) return c;
    final double step = (widget.max - widget.min) / d;
    return widget.min + ((c - widget.min) / step).round() * step;
  }

  void _update(double dx, double width, Haptics h) {
    final double t = (dx / width).clamp(0.0, 1.0);
    final double v = _snap(widget.min + t * (widget.max - widget.min));
    if (v == _v.value) return;
    _set(v);
    _haptics((v - widget.min) / (widget.max - widget.min), v, h);
    widget.onChanged(v);
  }

  /// A detent tick per step (every 10 % when continuous) and one edge bump
  /// on arriving at either end.
  void _haptics(double f, double v, Haptics h) {
    if (_edge == -1 && f > _edgeRearm || _edge == 1 && f < 1 - _edgeRearm) {
      _edge = 0;
    }
    final int edge = f <= 0
        ? -1
        : f >= 1
        ? 1
        : 0;
    final int detent = widget.divisions != null
        ? ((v - widget.min) / ((widget.max - widget.min) / widget.divisions!))
              .round()
        // The ends belong to the edge bump, not to a 0 % / 100 % detent.
        : (f * 10).floor().clamp(0, 9);
    if (edge != 0) {
      _lastDetent = detent;
      if (edge != _edge) {
        _edge = edge;
        h.play(HapticEvent.edge);
      }
    } else if (detent != _lastDetent) {
      _lastDetent = detent;
      // Leaving an end by a step is not a new detent.
      if (_edge == 0) h.play(HapticEvent.detent);
    }
  }

  double _stepped(double from, int dir) {
    final double step = widget.divisions != null
        ? (widget.max - widget.min) / widget.divisions!
        : (widget.max - widget.min) / 20;
    return _snap(from + dir * step);
  }

  String _text(double v) =>
      widget.valueText?.call(v) ??
      '${((v - widget.min) / (widget.max - widget.min) * 100).round()}%';

  void _stepBy(int dir) {
    final double v = _stepped(_v.value, dir);
    _set(v);
    widget.onChangeStart?.call(v);
    widget.onChanged(v);
    widget.onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final Haptics h = HapticsScope.of(context);
    final Color fill = widget.fill ?? Color(tone.accent);
    // Only the words follow the value here; the track repaints from [_v].
    return ValueListenableBuilder<String>(
      valueListenable: _shown,
      builder: (BuildContext context, String text, Widget? child) {
        final double v = _v.value;
        return Semantics(
          label: widget.semanticLabel,
          value: text,
          increasedValue: _text(_stepped(v, 1)),
          decreasedValue: _text(_stepped(v, -1)),
          enabled: widget.enabled,
          slider: true,
          onIncrease: widget.enabled ? () => _stepBy(1) : null,
          onDecrease: widget.enabled ? () => _stepBy(-1) : null,
          child: child,
        );
      },
      child: _body(context, tone, fill, h),
    );
  }

  Widget _body(BuildContext context, LightTone tone, Color fill, Haptics h) {
    final Widget Function(double)? trailingBuilder = widget.trailingBuilder;
    final Widget? trailing = trailingBuilder == null
        ? widget.trailing
        : ValueListenableBuilder<String>(
            valueListenable: _shown,
            builder: (BuildContext context, _, _) => trailingBuilder(_v.value),
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragDown: widget.enabled
              ? (_) => h.prepare(HapticEvent.detent)
              : null,
          onHorizontalDragStart: widget.enabled
              ? (DragStartDetails d) {
                  _dragging = true;
                  _lastDetent = -1;
                  _edge = 0;
                  _spring.stop();
                  widget.onChangeStart?.call(_v.value);
                  _update(d.localPosition.dx, width, h);
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (DragUpdateDetails d) => _update(d.localPosition.dx, width, h)
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  _dragging = false;
                  widget.onChangeEnd?.call(_v.value);
                }
              : null,
          onTapUp: widget.enabled
              ? (TapUpDetails d) {
                  _edge = 0;
                  widget.onChangeStart?.call(_v.value);
                  _update(d.localPosition.dx, width, h);
                  widget.onChangeEnd?.call(_v.value);
                }
              : null,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.45,
            child: SizedBox(
              height: widget.height,
              child: GlassSurface(
                radius: Radii.capsule,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _TrackPainter(
                      value: _v,
                      min: widget.min,
                      max: widget.max,
                      fill: fill,
                      track: widget.track,
                      dark: tone.dark,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.m),
                      child: Row(
                        children: <Widget>[
                          // At large text sizes the label shrinks to fit the
                          // pill instead of overflowing it.
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: widget.leading == null
                                  ? null
                                  : FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: widget.leading,
                                    ),
                            ),
                          ),
                          if (trailing != null) ...<Widget>[
                            const SizedBox(width: Space.s),
                            FittedBox(fit: BoxFit.scaleDown, child: trailing),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.fill,
    required this.track,
    required this.dark,
  }) : super(repaint: value);

  final ValueListenable<double> value;
  final double min;
  final double max;
  final Color fill;
  final List<Color>? track;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final double fraction = ((value.value - min) / (max - min)).clamp(0.0, 1.0);
    final RRect shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    canvas.save();
    canvas.clipRRect(shape);
    final List<Color>? t = track;
    if (t != null) {
      // Gradient slider: the whole track shows the range, a glass knob rides it.
      canvas.drawRRect(
        shape.deflate(3),
        Paint()
          ..shader = LinearGradient(colors: t).createShader(Offset.zero & size),
      );
      final double r = size.height / 2 - 4;
      final double x = r + 4 + fraction * (size.width - 2 * (r + 4));
      final Offset c = Offset(x, size.height / 2);
      canvas.drawCircle(
        c,
        r + 1.5,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawCircle(c, r, Paint()..color = Colors.white);
      canvas.drawCircle(
        c,
        r - 3,
        Paint()..color = Color.lerp(t.first, t.last, fraction)!,
      );
    } else if (fraction > 0) {
      // Pill slider: the filled part glows in the light's colour. It is a
      // capsule at least as wide as it is tall (the lowest value is a round
      // dot at the start, never a squashed sliver), so 0 is empty and 1 % is
      // not; its leading end carries a grip like a thumb.
      final double h = size.height;
      final double w = h + fraction * (size.width - h);
      final Rect rect = Rect.fromLTWH(0, 0, w, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(h / 2)),
        Paint()
          ..shader = LinearGradient(
            colors: <Color>[
              fill.withValues(alpha: dark ? 0.55 : 0.65),
              fill,
            ],
          ).createShader(rect),
      );
      final bool lightFill = fill.computeLuminance() > 0.45;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(w - h * 0.2, h / 2),
            width: 3,
            height: h * 0.4,
          ),
          const Radius.circular(1.5),
        ),
        Paint()
          ..color = lightFill
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.85),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.fill != fill ||
      old.track != track ||
      old.dark != dark;
}

/// Semantics helper for 1..10 level sliders ("Speed 5 of 10").
String levelText(double v) => '${v.round()} of 10';

/// Ensures semantics announcements are available (kept for API symmetry).
void announce(BuildContext context, String message) =>
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
