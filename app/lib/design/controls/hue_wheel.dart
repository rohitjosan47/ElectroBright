import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';

/// HSV value of the wheel (hue 0..360, saturation/value 0..1).
@immutable
final class Hsv {
  const Hsv(this.h, this.s, this.v);
  final double h;
  final double s;
  final double v;

  Color get color => HSVColor.fromAHSV(1, h, s, v).toColor();

  /// Keeps [previous] hue when the new colour is (near) grey or black, so the
  /// hue never snaps to red while the user drags into a corner.
  static Hsv fromColor(Color c, {Hsv? previous}) {
    final HSVColor x = HSVColor.fromColor(c);
    final bool hueless = x.saturation <= 0.05 || x.value <= 0.05;
    return Hsv(
      hueless && previous != null ? previous.h : x.hue,
      x.saturation,
      x.value,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Hsv && other.h == h && other.s == s && other.v == v;
  @override
  int get hashCode => Object.hash(h, s, v);
}

enum _Target { ring, square }

/// Hue ring with an inner saturation/value square (the design chosen in the
/// previous app), rebuilt: responsive, repaint-isolated, a magnifying glass
/// thumb, hue detent haptics and full screen-reader support.
class HueWheel extends StatefulWidget {
  const HueWheel({
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.maxSize = 300,
    this.enabled = true,
    super.key,
  });

  final Hsv value;
  final ValueChanged<Hsv> onChanged;
  final VoidCallback? onChangeStart;
  final ValueChanged<Hsv>? onChangeEnd;
  final double maxSize;
  final bool enabled;

  @override
  State<HueWheel> createState() => _HueWheelState();
}

class _HueWheelState extends State<HueWheel>
    with SingleTickerProviderStateMixin {
  late final ValueNotifier<Hsv> _v = ValueNotifier<Hsv>(widget.value);
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  _Target? _target;
  int _lastHueDetent = -1;
  bool _atEdge = false;

  @override
  void didUpdateWidget(HueWheel old) {
    super.didUpdateWidget(old);
    if (_target == null && widget.value != _v.value) {
      _v.value =
          Hsv.fromColor(widget.value.color, previous: _v.value) ==
              Hsv.fromColor(_v.value.color, previous: _v.value)
          ? _v
                .value // same colour: keep our (precise) hue
          : widget.value;
    }
  }

  @override
  void dispose() {
    _v.dispose();
    _press.dispose();
    super.dispose();
  }

  static ({double rOut, double rIn, double half}) _geometry(double size) {
    final double rOut = size / 2 - 8;
    final double thickness = size * 0.095;
    final double rIn = rOut - thickness;
    return (rOut: rOut, rIn: rIn, half: (rIn - 10) / math.sqrt2);
  }

  void _down(Offset p, double size, Haptics h) {
    final ({double rOut, double rIn, double half}) g = _geometry(size);
    final Offset d = p - Offset(size / 2, size / 2);
    if (d.dx.abs() <= g.half + 6 && d.dy.abs() <= g.half + 6) {
      _target = _Target.square;
    } else if (d.distance >= g.rIn - 10 && d.distance <= g.rOut + 12) {
      _target = _Target.ring;
    } else {
      _target = null;
      return;
    }
    h.prepare(HapticEvent.hueDetent);
    _lastHueDetent = (_v.value.h / 30).floor();
    _press.forward();
    widget.onChangeStart?.call();
    _move(p, size, h);
  }

  void _move(Offset p, double size, Haptics h) {
    final _Target? t = _target;
    if (t == null) return;
    final ({double rOut, double rIn, double half}) g = _geometry(size);
    final Offset d = p - Offset(size / 2, size / 2);
    final Hsv cur = _v.value;
    Hsv next;
    if (t == _Target.ring) {
      double deg = math.atan2(d.dy, d.dx) * 180 / math.pi;
      if (deg < 0) deg += 360;
      next = Hsv(deg, cur.s, cur.v);
      final int detent = (deg / 30).floor();
      if (detent != _lastHueDetent) {
        _lastHueDetent = detent;
        h.play(
          detent % 4 == 0 ? HapticEvent.hueDetentStrong : HapticEvent.hueDetent,
        );
      }
    } else {
      final double x = d.dx.clamp(-g.half, g.half);
      final double y = d.dy.clamp(-g.half, g.half);
      next = Hsv(
        cur.h,
        (x + g.half) / (2 * g.half),
        1 - (y + g.half) / (2 * g.half),
      );
      final bool edge = d.dx.abs() >= g.half || d.dy.abs() >= g.half;
      if (edge && !_atEdge) h.play(HapticEvent.edge, intensity: 0.6);
      _atEdge = edge;
    }
    if (next == cur) return;
    _v.value = next;
    widget.onChanged(next);
  }

  void _up() {
    if (_target == null) return;
    _target = null;
    _atEdge = false;
    _press.reverse();
    widget.onChangeEnd?.call(_v.value);
  }

  void _nudge(Hsv next) {
    _v.value = next;
    widget.onChangeStart?.call();
    widget.onChanged(next);
    widget.onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final Haptics h = HapticsScope.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double size = math.min(c.maxWidth, widget.maxSize);
        return Center(
          child: SizedBox.square(
            dimension: size,
            child: ValueListenableBuilder<Hsv>(
              valueListenable: _v,
              builder: (BuildContext context, Hsv v, Widget? child) => Semantics(
                label: 'Colour',
                value:
                    'hue ${v.h.round()} degrees, saturation '
                    '${(v.s * 100).round()}%, brightness ${(v.v * 100).round()}%',
                customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
                  const CustomSemanticsAction(
                    label: 'Hue plus 10 degrees',
                  ): () =>
                      _nudge(Hsv((v.h + 10) % 360, v.s, v.v)),
                  const CustomSemanticsAction(
                    label: 'Hue minus 10 degrees',
                  ): () =>
                      _nudge(Hsv((v.h + 350) % 360, v.s, v.v)),
                  const CustomSemanticsAction(label: 'More saturated'): () =>
                      _nudge(Hsv(v.h, (v.s + 0.1).clamp(0, 1), v.v)),
                  const CustomSemanticsAction(label: 'Less saturated'): () =>
                      _nudge(Hsv(v.h, (v.s - 0.1).clamp(0, 1), v.v)),
                },
                child: child,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onPanDown: widget.enabled
                    ? (DragDownDetails d) => _down(d.localPosition, size, h)
                    : null,
                onPanUpdate: widget.enabled
                    ? (DragUpdateDetails d) => _move(d.localPosition, size, h)
                    : null,
                onPanEnd: widget.enabled ? (_) => _up() : null,
                onPanCancel: widget.enabled ? _up : null,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _WheelPainter(_v, _press),
                    size: Size.square(size),
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

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.v, this.press)
    : super(repaint: Listenable.merge(<Listenable>[v, press]));
  final ValueNotifier<Hsv> v;
  final Animation<double> press;

  static const List<Color> _spectrum = <Color>[
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final Hsv hsv = v.value;
    final ({double rOut, double rIn, double half}) g = _HueWheelState._geometry(
      size.width,
    );
    final Offset c = size.center(Offset.zero);
    final double ringW = g.rOut - g.rIn;
    final double mid = (g.rOut + g.rIn) / 2;

    // Ring (0° = red at 3 o'clock, clockwise).
    canvas.drawCircle(
      c,
      mid,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringW
        ..shader = const SweepGradient(colors: _spectrum)
            .createShader(Rect.fromCircle(center: c, radius: g.rOut)),
    );

    // Square: pure hue, white to the left, black to the bottom.
    final Rect sq = Rect.fromCenter(
      center: c,
      width: g.half * 2,
      height: g.half * 2,
    );
    final RRect rr = RRect.fromRectAndRadius(sq, const Radius.circular(14));
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      sq,
      Paint()..color = HSVColor.fromAHSV(1, hsv.h, 1, 1).toColor(),
    );
    canvas.drawRect(
      sq,
      Paint()
        ..shader = const LinearGradient(
          colors: <Color>[Colors.white, Color(0x00FFFFFF)],
        ).createShader(sq),
    );
    canvas.drawRect(
      sq,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x00000000), Colors.black],
        ).createShader(sq),
    );
    canvas.restore();

    final double grow = press.value;
    // Hue thumb on the ring.
    final double a = hsv.h * math.pi / 180;
    _thumb(
      canvas,
      c + Offset(math.cos(a), math.sin(a)) * mid,
      ringW / 2 + 3 + grow * 4,
      HSVColor.fromAHSV(1, hsv.h, 1, 1).toColor(),
    );
    // Square thumb: a glass lens that magnifies while dragging.
    _thumb(
      canvas,
      Offset(sq.left + hsv.s * sq.width, sq.top + (1 - hsv.v) * sq.height),
      11 + grow * 9,
      hsv.color,
    );
  }

  void _thumb(Canvas canvas, Offset p, double r, Color fill) {
    canvas.drawCircle(
      p,
      r + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(p, r + 1.5, Paint()..color = Colors.white);
    canvas.drawCircle(p, r - 1.5, Paint()..color = fill);
    // Specular highlight: a touch of glass.
    canvas.drawCircle(
      p - Offset(r * 0.28, r * 0.32),
      r * 0.42,
      Paint()
        ..shader =
            RadialGradient(
              colors: <Color>[
                Colors.white.withValues(alpha: 0.55),
                Colors.white.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: p - Offset(r * 0.28, r * 0.32),
                radius: r * 0.42,
              ),
            ),
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.v != v || old.press != press;
}
