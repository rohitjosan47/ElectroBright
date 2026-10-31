import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';

/// A Flash (identify) control: [builder] gets the animated flare icon and a
/// `flash` callback to call with the action. The icon then bursts twice, in
/// time with the light's two flashes: it pops and turns, a warm glow blooms
/// behind it and a ring ripples out, with a haptic tap on each beat. Under
/// Reduce Motion only the glow plays.
class FlashAction extends StatefulWidget {
  const FlashAction({required this.builder, this.iconSize = 24, super.key});

  final Widget Function(BuildContext context, Widget icon, VoidCallback flash)
  builder;
  final double iconSize;

  @override
  State<FlashAction> createState() => _FlashActionState();
}

class _FlashActionState extends State<FlashAction>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 1150);

  /// Where the second beat starts (fraction of [_duration]).
  static const double _second = 0.42;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _duration,
  )..addListener(_beat);

  bool _secondPlayed = false;

  void _beat() {
    if (!_secondPlayed && _c.value >= _second) {
      _secondPlayed = true;
      HapticsScope.of(context).play(HapticEvent.edge);
    }
  }

  void _flash() {
    _secondPlayed = false;
    HapticsScope.of(context).play(HapticEvent.powerOn);
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    _FlashIcon(
      animation: _c,
      size: widget.iconSize,
      second: _second,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    ),
    _flash,
  );
}

class _FlashIcon extends AnimatedWidget {
  const _FlashIcon({
    required Animation<double> animation,
    required this.size,
    required this.second,
    required this.reduceMotion,
  }) : super(listenable: animation);

  final double size;
  final double second;
  final bool reduceMotion;

  static const Color _flashColour = Color(0xFFFFC94D);

  /// Progress 0..1 of the beat starting at [start] (each lasts [length]).
  static double _beat(double t, double start, double length) =>
      ((t - start) / length).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final double t = (listenable as Animation<double>).value;
    final Color base = IconTheme.of(context).color ?? Colors.white;
    final double len = 1 - second;
    final double p1 = _beat(t, 0, second + 0.08);
    final double p2 = _beat(t, second, len);
    // 0 → 1 → 0 per beat, the second a little softer.
    double swell(double p) => p <= 0 || p >= 1 ? 0 : math.sin(math.pi * p);
    final double glow = math.max(swell(p1), swell(p2) * 0.85);
    final double pop = reduceMotion
        ? 0
        : math.max(
            Curves.easeOutBack.transform(swell(p1)),
            Curves.easeOutBack.transform(swell(p2)) * 0.8,
          );
    // A quarter turn over the whole animation, settling softly.
    final double turn = reduceMotion || t >= 1
        ? 0
        : Curves.easeOutCubic.transform(t) * math.pi / 2;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BurstPainter(
          glow: glow,
          rings: reduceMotion ? const <double>[] : <double>[p1, p2],
          colour: _flashColour,
        ),
        child: Transform.rotate(
          angle: turn,
          child: Transform.scale(
            scale: 1 + 0.32 * pop,
            child: Icon(
              Icons.flare_rounded,
              size: size,
              color: Color.lerp(base, _flashColour, glow),
              shadows: glow <= 0
                  ? null
                  : <Shadow>[
                      Shadow(
                        color: _flashColour.withValues(alpha: 0.8 * glow),
                        blurRadius: 10 * glow,
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The glow behind the icon and one ripple ring per beat (painted outside
/// the icon's box, so the button's layout never moves).
class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.glow,
    required this.rings,
    required this.colour,
  });

  final double glow;
  final List<double> rings;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    if (glow > 0) {
      final double reach = r * (1.2 + 0.6 * glow);
      canvas.drawCircle(
        c,
        reach,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              colour.withValues(alpha: 0.55 * glow),
              colour.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: reach)),
      );
    }
    for (final double p in rings) {
      if (p <= 0 || p >= 1) continue;
      final double e = Curves.easeOutCubic.transform(p);
      canvas.drawCircle(
        c,
        r * (0.7 + 1.3 * e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * (1 - e) + 0.5
          ..color = colour.withValues(alpha: 0.7 * (1 - e)),
      );
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) =>
      old.glow != glow || old.colour != colour || old.rings != rings;
}
