import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/protocol/eb/mode_catalog.dart';

/// A tiny animated illustration of a lighting mode, drawn in [color] (the
/// light's colour) or the mode's own palette. Animates only while [animate]
/// and when motion is allowed; otherwise shows a representative still frame.
class ModeGlyph extends StatefulWidget {
  const ModeGlyph({
    required this.glyph,
    required this.color,
    this.palette = const <Color>[],
    this.animate = true,
    this.speed = 1,
    super.key,
  });

  final EbModeGlyph glyph;
  final Color color;

  /// The mode's own colours (used by modes that ignore the picked colour).
  final List<Color> palette;
  final bool animate;

  /// Animation rate multiplier (follows the mode's speed slider).
  final double speed;

  @override
  State<ModeGlyph> createState() => _ModeGlyphState();
}

class _ModeGlyphState extends State<ModeGlyph>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  // The still frame (Reduce Motion, off-screen): chosen so every glyph shows a
  // lit moment (blink on, police beacon lit, storm at rest).
  final ValueNotifier<double> _t = ValueNotifier<double>(1.30);
  Duration _last = Duration.zero;
  Duration _acc = Duration.zero;

  // Mode previews are capped at 30 fps (plan §11): plenty for a glyph.
  static const Duration _frame = Duration(microseconds: 33333);

  void _onTick(Duration elapsed) {
    final Duration dt = elapsed - _last;
    _last = elapsed;
    _acc += dt;
    if (_acc < _frame) return;
    _t.value += _acc.inMicroseconds / 1e6 * widget.speed;
    _acc = Duration.zero;
  }

  void _sync() {
    final bool run =
        widget.animate &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ModeGlyph old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  // Fills whatever slot it is given (a childless CustomPaint would size to
  // zero under loose constraints).
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.expand(
      child: CustomPaint(
        painter: GlyphPainter(widget.glyph, widget.color, widget.palette, _t),
      ),
    ),
  );
}

/// Paints one glyph at time [t] (seconds). Public so the light orb can reuse it.
class GlyphPainter extends CustomPainter {
  GlyphPainter(this.glyph, this.color, this.palette, this.t)
    : super(repaint: t);
  final EbModeGlyph glyph;
  final Color color;
  final List<Color> palette;
  final ValueNotifier<double> t;

  static double _noise(double x) {
    // Cheap smooth value noise.
    final int i = x.floor();
    final double f = x - i;
    double h(int n) {
      final double s = math.sin(n * 127.1 + 311.7) * 43758.5453;
      return s - s.floor();
    }

    final double u = f * f * (3 - 2 * f);
    return h(i) * (1 - u) + h(i + 1) * u;
  }

  Color _pal(int i) => palette.isEmpty ? color : palette[i % palette.length];

  @override
  void paint(Canvas canvas, Size size) {
    final double time = t.value;
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;

    void glow(Offset p, double radius, Color col, double level) {
      if (level <= 0.01) return;
      canvas.drawCircle(
        p,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              col.withValues(alpha: level),
              col.withValues(alpha: level * 0.35),
              col.withValues(alpha: 0),
            ],
            stops: const <double>[0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: p, radius: radius)),
      );
    }

    switch (glyph) {
      case EbModeGlyph.solid:
        glow(c, r * 0.95, color, 0.9);
      case EbModeGlyph.blink:
        glow(c, r * 0.95, color, (time * 1.6) % 1 < 0.5 ? 0.95 : 0.08);
      case EbModeGlyph.breath:
        final double b = 0.5 - 0.5 * math.cos(time * 1.4);
        glow(c, r * (0.55 + 0.4 * b), color, 0.25 + 0.7 * b);
      case EbModeGlyph.fireworks:
        for (int k = 0; k < 3; k++) {
          final double phase = (time * 0.7 + k / 3) % 1;
          final Offset o =
              c +
              Offset(
                math.cos(k * 2.1) * r * 0.35,
                math.sin(k * 2.7) * r * 0.25,
              );
          final Color col = _pal(k);
          for (int s = 0; s < 9; s++) {
            final double a = s / 9 * 2 * math.pi + k;
            final Offset p =
                o + Offset(math.cos(a), math.sin(a)) * (r * 0.55 * phase);
            canvas.drawCircle(
              p,
              r * 0.05,
              Paint()..color = col.withValues(alpha: (1 - phase) * 0.95),
            );
          }
        }
      case EbModeGlyph.tv:
        final Rect scr = Rect.fromCenter(
          center: c,
          width: r * 1.5,
          height: r * 1.05,
        );
        final double lum = 0.35 + 0.65 * _noise(time * 3);
        canvas.drawRRect(
          RRect.fromRectAndRadius(scr, Radius.circular(r * 0.12)),
          Paint()
            ..color = Color.lerp(
              _pal(0),
              _pal(1),
              _noise(time * 0.7),
            )!.withValues(alpha: lum),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(scr, Radius.circular(r * 0.12)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.06
            ..color = Colors.white.withValues(alpha: 0.35),
        );
      case EbModeGlyph.thunder:
        final double cyc = time % 3.2;
        final double flash = cyc < 0.08
            ? 1
            : cyc < 0.16
            ? 0.2
            : cyc < 0.24
            ? 0.85
            : cyc < 0.6
            ? 0.25 * (0.6 - cyc) / 0.36
            : 0;
        // A faint resting glow keeps the storm readable between strokes.
        glow(c, r, color, 0.14 + flash * 0.8);
        final Path bolt = Path()
          ..moveTo(c.dx + r * 0.10, c.dy - r * 0.62)
          ..lineTo(c.dx - r * 0.22, c.dy + r * 0.05)
          ..lineTo(c.dx + r * 0.02, c.dy + r * 0.05)
          ..lineTo(c.dx - r * 0.12, c.dy + r * 0.62)
          ..lineTo(c.dx + r * 0.28, c.dy - r * 0.12)
          ..lineTo(c.dx + r * 0.04, c.dy - r * 0.12)
          ..close();
        canvas.drawPath(
          bolt,
          Paint()
            ..color = Color.lerp(
              color,
              Colors.white,
              0.25 + 0.5 * flash,
            )!.withValues(alpha: 0.65 + 0.35 * flash),
        );
      case EbModeGlyph.faulty:
        final double n = _noise(time * 9);
        glow(
          c,
          r * 0.9,
          color,
          n > 0.62 ? 0.08 : 0.55 + 0.4 * _noise(time * 23),
        );
      case EbModeGlyph.welding:
        final double arc = 0.6 + 0.4 * _noise(time * 40);
        glow(c + Offset(0, r * 0.2), r * 0.7, color, arc * 0.9);
        for (int s = 0; s < 7; s++) {
          final double ph = (time * 1.8 + s * 0.37) % 1;
          final double a = -math.pi / 2 + (s - 3) * 0.35;
          final Offset p =
              c +
              Offset(0, r * 0.2) +
              Offset(math.cos(a), math.sin(a)) * r * 0.8 * ph +
              Offset(0, r * 0.6 * ph * ph);
          canvas.drawCircle(
            p,
            r * 0.035,
            Paint()
              ..color = Color.lerp(
                color,
                const Color(0xFFFFE0A0),
                0.6,
              )!.withValues(alpha: 1 - ph),
          );
        }
      case EbModeGlyph.club:
        for (int k = 0; k < 3; k++) {
          final double a = time * 2.2 + k * 2 * math.pi / 3;
          final bool on = ((time * 2.5).floor() + k) % 3 != 0;
          glow(
            c + Offset(math.cos(a), math.sin(a)) * r * 0.45,
            r * 0.5,
            _pal(k),
            on ? 0.85 : 0.1,
          );
        }
      case EbModeGlyph.rainbow:
        final Rect ring = Rect.fromCircle(center: c, radius: r * 0.7);
        canvas.drawCircle(
          c,
          r * 0.7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.28
            ..shader = SweepGradient(
              colors: const <Color>[
                Color(0xFFFF0000),
                Color(0xFFFFFF00),
                Color(0xFF00FF00),
                Color(0xFF00FFFF),
                Color(0xFF0000FF),
                Color(0xFFFF00FF),
                Color(0xFFFF0000),
              ],
              transform: GradientRotation(time * 0.9),
            ).createShader(ring),
        );
      case EbModeGlyph.fire:
      case EbModeGlyph.candle:
        final bool candle = glyph == EbModeGlyph.candle;
        final double scale = candle ? 0.55 : 1;
        final double w = r * 0.55 * scale;
        final double h = r * 1.3 * scale;
        final Offset base = c + Offset(0, candle ? r * 0.1 : r * 0.55);
        final double sway = (_noise(time * (candle ? 2 : 5)) - 0.5) * w * 0.6;
        final double tall = 0.85 + 0.3 * _noise(time * (candle ? 3 : 7) + 9);
        final Path flame = Path()
          ..moveTo(base.dx - w, base.dy)
          ..quadraticBezierTo(
            base.dx - w * 1.1,
            base.dy - h * 0.55,
            base.dx + sway,
            base.dy - h * tall,
          )
          ..quadraticBezierTo(
            base.dx + w * 1.1,
            base.dy - h * 0.55,
            base.dx + w,
            base.dy,
          )
          ..close();
        glow(
          base - Offset(0, h * 0.4),
          r * (candle ? 0.8 : 1),
          color,
          0.45 + 0.3 * _noise(time * 6),
        );
        canvas.drawPath(
          flame,
          Paint()
            ..shader =
                LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: <Color>[
                    Color.lerp(color, Colors.white, 0.55)!,
                    color,
                    color.withValues(alpha: 0),
                  ],
                ).createShader(
                  Rect.fromLTRB(base.dx - w, base.dy - h, base.dx + w, base.dy),
                ),
        );
        if (candle) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                c.dx - r * 0.16,
                c.dy + r * 0.1,
                r * 0.32,
                r * 0.72,
              ),
              Radius.circular(r * 0.06),
            ),
            Paint()..color = Colors.white.withValues(alpha: 0.75),
          );
        }
      case EbModeGlyph.police:
        final bool left = (time * 2.4).floor().isEven;
        final bool flicker = (time * 14).floor().isEven;
        glow(
          c - Offset(r * 0.42, 0),
          r * 0.6,
          _pal(0),
          left && flicker ? 0.95 : 0.08,
        );
        glow(
          c + Offset(r * 0.42, 0),
          r * 0.6,
          _pal(1),
          !left && flicker ? 0.95 : 0.08,
        );
    }
  }

  @override
  bool shouldRepaint(GlyphPainter old) =>
      old.glyph != glyph || old.color != color || old.t != t;
}
