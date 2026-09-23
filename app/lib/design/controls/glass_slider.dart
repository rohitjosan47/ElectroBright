import 'package:flutter/material.dart';
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
    this.valueText,
    this.enabled = true,
    super.key,
  });

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
  final String semanticLabel;
  final String Function(double value)? valueText;
  final bool enabled;

  @override
  State<GlassSlider> createState() => _GlassSliderState();
}

class _GlassSliderState extends State<GlassSlider> {
  late final ValueNotifier<double> _v = ValueNotifier<double>(widget.value);
  bool _dragging = false;
  int _lastDetent = -1;

  @override
  void didUpdateWidget(GlassSlider old) {
    super.didUpdateWidget(old);
    // External updates never move the control under the finger.
    if (!_dragging) _v.value = widget.value;
  }

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
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
    _v.value = v;
    final double f = (v - widget.min) / (widget.max - widget.min);
    final int detent = widget.divisions != null
        ? ((v - widget.min) / ((widget.max - widget.min) / widget.divisions!))
              .round()
        : (f * 10).floor();
    if (detent != _lastDetent) {
      _lastDetent = detent;
      h.play(f <= 0 || f >= 1 ? HapticEvent.edge : HapticEvent.detent);
    }
    widget.onChanged(v);
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
    _v.value = v;
    widget.onChangeStart?.call(v);
    widget.onChanged(v);
    widget.onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final Haptics h = HapticsScope.of(context);
    final Color fill = widget.fill ?? Color(tone.accent);
    return ValueListenableBuilder<double>(
      valueListenable: _v,
      builder: (BuildContext context, double v, _) => Semantics(
        label: widget.semanticLabel,
        value: _text(v),
        increasedValue: _text(_stepped(v, 1)),
        decreasedValue: _text(_stepped(v, -1)),
        enabled: widget.enabled,
        slider: true,
        onIncrease: widget.enabled ? () => _stepBy(1) : null,
        onDecrease: widget.enabled ? () => _stepBy(-1) : null,
        child: child(context, v, tone, fill, h),
      ),
    );
  }

  Widget child(
    BuildContext context,
    double v,
    LightTone tone,
    Color fill,
    Haptics h,
  ) {
    final double f = ((v - widget.min) / (widget.max - widget.min)).clamp(
      0.0,
      1.0,
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
                      fraction: f,
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
                          if (widget.trailing != null) ...<Widget>[
                            const SizedBox(width: Space.s),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: widget.trailing,
                            ),
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
    required this.fraction,
    required this.fill,
    required this.track,
    required this.dark,
  });

  final double fraction;
  final Color fill;
  final List<Color>? track;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
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
    } else {
      // Pill slider: the filled part glows in the light's colour.
      final double w = fraction * size.width;
      if (w > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, w, size.height),
            Radius.circular(size.height / 2),
          ),
          Paint()
            ..shader = LinearGradient(
              colors: <Color>[
                fill.withValues(alpha: dark ? 0.55 : 0.65),
                fill,
              ],
            ).createShader(Rect.fromLTWH(0, 0, w, size.height)),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.fraction != fraction ||
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
