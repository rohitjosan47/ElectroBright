import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/color/light_surfaces.dart';
import '../../core/protocol/eb/mode_catalog.dart';
import '../tone/tone_scope.dart';

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

  /// The frame shown when the glyph is still (Reduce Motion): each glyph's
  /// characteristic moment, not the start of its loop.
  static double stillTime(EbModeGlyph glyph) => switch (glyph) {
    EbModeGlyph.blink => 0.1, // lit
    EbModeGlyph.breath => 1.78, // near a full breath
    EbModeGlyph.thunder => 0.04, // a stroke
    EbModeGlyph.fireworks => 0.64, // bursts half open
    _ => 1.30,
  };

  @override
  State<ModeGlyph> createState() => _ModeGlyphState();
}

class _ModeGlyphState extends State<ModeGlyph>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  // Starts on the still frame; runs on from there when animated.
  late final ValueNotifier<double> _t = ValueNotifier<double>(
    ModeGlyph.stillTime(widget.glyph),
  );
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
    } else if (!run) {
      if (_ticker.isActive) _ticker.stop();
      _t.value = ModeGlyph.stillTime(widget.glyph);
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
  Widget build(BuildContext context) {
    // Light: the full rendering in the light's own colours, plus a coloured
    // under-light and, for colours too light to show on a tile, a deeper
    // shade of the colour in the glow's halo (never a ring).
    final bool dark = ToneScope.darkOf(context);
    final LightSurfaces? light = dark
        ? null
        : LightSurfaces(ToneScope.of(context));
    final int? outline = light?.glyphOutline(widget.color.toARGB32());
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: GlyphPainter(
            widget.glyph,
            widget.color,
            widget.palette,
            _t,
            under: light == null
                ? null
                : Color(light.underLight(widget.color.toARGB32())),
            outline: outline == null ? null : Color(outline),
          ),
        ),
      ),
    );
  }
}

/// Paints one glyph at time [t] (seconds). Public so the light orb can reuse it.
class GlyphPainter extends CustomPainter {
  GlyphPainter(
    this.glyph,
    this.color,
    this.palette,
    this.t, {
    this.under,
    this.outline,
  }) : super(repaint: t);
  final EbModeGlyph glyph;
  final Color color;
  final List<Color> palette;
  final ValueNotifier<double> t;

  /// Light theme: the glyph's colour shining onto the tile below it.
  final Color? under;

  /// Light theme: a deeper shade for a glyph too light to show on its tile
  /// (the halo of its glow, the edge of a screen).
  final Color? outline;

  bool get _light => under != null;

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

  /// The rainbow's bands, inside (violet) to outside (red): a refined,
  /// vivid spectrum.
  static const List<Color> _spectrum = <Color>[
    Color(0xFFB45CF0),
    Color(0xFF5E5CE6),
    Color(0xFF0A84FF),
    Color(0xFF30D158),
    Color(0xFFFFD60A),
    Color(0xFFFF9F0A),
    Color(0xFFFF453A),
  ];

  /// A glowing rainbow arch: continuous bands (red outside to violet
  /// inside, or warm to cool whites on a tunable-white light) with a soft
  /// halo, ends fading into mist, a gleam of light gliding along it, the
  /// halo breathing and a few sparkles twinkling on its outer edge.
  void _rainbow(Canvas canvas, Offset c, double r, double time) {
    // Rainbow's own colours: the spectrum; anything else is the light's
    // rendering of it (warm to cool whites on a tunable-white light), shown
    // inside (cool) to outside (warm).
    final List<int> own = EbModeCatalog.modes
        .firstWhere((EbModeSpec m) => m.glyph == EbModeGlyph.rainbow)
        .gradient;
    final bool ownColours =
        palette.isEmpty ||
        (palette.length == own.length &&
            <int>[for (final Color p in palette) p.toARGB32()].indexed
                .every(((int, int) e) => e.$2 == own[e.$1]));
    final List<Color> bands = ownColours
        ? _spectrum
        : palette.reversed.toList();
    final Offset o = c + Offset(0, r * 0.42);
    final double outer = r * 0.95, inner = r * 0.47;
    final double width = outer - inner;
    final Rect arc = Rect.fromCircle(center: o, radius: (outer + inner) / 2);
    final Rect disc = Rect.fromCircle(center: o, radius: outer);
    final Shader spectrum = RadialGradient(
      colors: bands,
      stops: <double>[
        for (int i = 0; i < bands.length; i++)
          (inner + width * (i + 0.5) / bands.length) / outer,
      ],
    ).createShader(disc);
    final Rect bounds = disc.inflate(r * 0.25);
    final BlendMode add = _light ? BlendMode.srcOver : BlendMode.plus;
    canvas.saveLayer(bounds, Paint());
    // The halo, breathing.
    final double breathe = 0.5 + 0.5 * math.sin(time * 1.3);
    canvas.drawArc(
      arc,
      math.pi,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 1.15
        ..shader = spectrum
        ..color = Color.fromRGBO(
          0,
          0,
          0,
          (_light ? 0.3 : 0.45) + 0.15 * breathe,
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.12),
    );
    // The bands.
    canvas.drawArc(
      arc,
      math.pi,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = spectrum
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.012),
    );
    // A gleam gliding along the arch (entering and leaving past the ends).
    final double sweep = (time * 0.32) % 1;
    final double at = math.pi - 0.5 + sweep * (math.pi + 1);
    canvas.drawArc(
      arc,
      math.pi,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 0.9
        ..blendMode = add
        ..shader = SweepGradient(
          startAngle: at - 0.32,
          endAngle: at + 0.32,
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            // Softer on white bands (white on white blows out).
            Colors.white.withValues(
              alpha: (_light ? 0.55 : 0.5) * (ownColours ? 1 : 0.45),
            ),
            Colors.white.withValues(alpha: 0),
          ],
          tileMode: TileMode.decal,
        ).createShader(bounds)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.03),
    );
    // Sparkles twinkling on the outer edge, each in its own rhythm.
    for (final (double a, double phase) in <(double, double)>[
      (math.pi * 1.22, 0),
      (math.pi * 1.55, 2.1),
      (math.pi * 1.8, 4.2),
    ]) {
      final double tw = math
          .pow(math.max(0, math.sin(time * 1.7 + phase)), 8)
          .toDouble();
      if (tw < 0.02) continue;
      final Offset p =
          o + Offset(math.cos(a), math.sin(a)) * (outer + r * 0.05);
      final double s = r * 0.11 * (0.6 + 0.4 * tw);
      final Paint star = Paint()
        ..color = Colors.white.withValues(alpha: (_light ? 0.9 : 0.85) * tw)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.008);
      canvas.drawOval(
        Rect.fromCenter(center: p, width: s * 2, height: s * 0.28),
        star,
      );
      canvas.drawOval(
        Rect.fromCenter(center: p, width: s * 0.28, height: s * 2),
        star,
      );
    }
    // The ends fade into mist.
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = SweepGradient(
          startAngle: math.pi,
          endAngle: 2 * math.pi,
          colors: const <Color>[
            Color(0x00000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          stops: const <double>[0, 0.24, 0.76, 1],
        ).createShader(bounds),
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double time = t.value;
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;

    // Light: the colour cast onto the tile, below everything else.
    final Color? cast = glyph == EbModeGlyph.rainbow ? null : under;
    if (cast != null) {
      final Offset below = c + Offset(0, r * 0.2);
      canvas.drawCircle(
        below,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              cast.withValues(alpha: 0.3),
              cast.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: below, radius: r)),
      );
    }

    void glow(Offset p, double radius, Color col, double level) {
      if (level <= 0.01) return;
      // Full colour at the core, falling off gently (the light's own colour,
      // not a pastel of it). A colour too light to show on a light tile keeps
      // its bright core; a deeper shade of itself tints the soft halo, so the
      // glow still reads (no ring, no dark spot).
      final Color? deep = outline;
      final Color halo = deep == null ? col : Color.lerp(col, deep, 0.7)!;
      canvas.drawCircle(
        p,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              col.withValues(alpha: level),
              halo.withValues(alpha: level * 0.5),
              (deep ?? col).withValues(alpha: 0),
            ],
            stops: const <double>[0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: p, radius: radius)),
      );
    }

    switch (glyph) {
      case EbModeGlyph.solid:
        glow(c, r * 0.95, color, 1);
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
            // Light: a white edge vanishes on a light tile.
            ..color = _light
                ? (outline ?? Colors.black.withValues(alpha: 0.18))
                : Colors.white.withValues(alpha: 0.35),
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
        _rainbow(canvas, c, r, time);
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
      old.glyph != glyph ||
      old.color != color ||
      old.under != under ||
      old.outline != outline ||
      !listEquals(old.palette, palette) ||
      old.t != t;
}
