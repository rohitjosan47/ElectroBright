import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/color/light_tone.dart';
import '../tone/light_level.dart';
import '../tone/tone_scope.dart';

/// The ambient background: the light's colour spilling in from the top over a
/// deep (dark) or pale (light) field, with a static dither so dark gradients
/// never band. One draw; repaints when the tone changes and, on a light's
/// screen, as its brightness glides (LightLevel), without rebuilding.
class AmbientCanvas extends StatelessWidget {
  const AmbientCanvas({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final Animation<double> level = LightLevel.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: CustomPaint(
            painter: _CanvasPainter(tone, level, _Dither.image),
          ),
        ),
        child,
      ],
    );
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter(this.tone, this.level, this.dither) : super(repaint: level);
  final LightTone tone;
  final Animation<double> level;
  final ui.Image? dither;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    final double b = level.value.clamp(0.0, 1.0);
    // As before the tone ignored brightness: the top of the field lifts and
    // the glow grows with the light (0.25 + 0.75 × brightness), fading out
    // over the last few percent so turning off has no step.
    final double glowStrength =
        tone.glowStrength * (0.25 + 0.75 * b) * math.min(1, b * 20);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color.lerp(Color(tone.canvasDim), Color(tone.canvas[0]), b)!,
            Color(tone.canvas[1]),
            Color(tone.canvas[2]),
          ],
          stops: const <double>[0, 0.45, 1],
        ).createShader(r),
    );
    if (glowStrength > 0) {
      final double radius = math.max(size.width, size.height) * 0.75;
      final Offset c = Offset(size.width * 0.5, -size.height * 0.08);
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Color(tone.glow)
                  .withValues(alpha: (tone.dark ? 0.42 : 0.30) * glowStrength),
              Color(tone.glow).withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    }
    final ui.Image? d = dither;
    if (d != null) {
      canvas.drawRect(
        r,
        Paint()
          ..shader = ImageShader(
            d,
            TileMode.repeated,
            TileMode.repeated,
            Matrix4.identity().storage,
          )
          ..blendMode = BlendMode.overlay
          ..color = const Color(0x14FFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.tone != tone || old.level != level || old.dither != dither;
}

/// A 64x64 blue-ish noise tile generated once at startup.
abstract final class _Dither {
  static ui.Image? image;
  static bool _started = false;

  static void ensure() {
    if (_started) return;
    _started = true;
    const int n = 64;
    final math.Random rnd = math.Random(7);
    final Uint8List px = Uint8List(n * n * 4);
    for (int i = 0; i < n * n; i++) {
      final int v = 96 + rnd.nextInt(64);
      px[i * 4] = v;
      px[i * 4 + 1] = v;
      px[i * 4 + 2] = v;
      px[i * 4 + 3] = 255;
    }
    ui.decodeImageFromPixels(px, n, n, ui.PixelFormat.rgba8888, (ui.Image i) {
      image = i;
    });
  }
}

/// Call once before the first frame (starts the dither tile decode).
void prepareAmbientCanvas() => _Dither.ensure();
