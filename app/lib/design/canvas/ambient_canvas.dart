import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/color/light_tone.dart';
import '../tone/tone_scope.dart';

/// The ambient background: the light's colour spilling in from the top over a
/// deep (dark) or pale (light) field, with a static dither so dark gradients
/// never band. One draw; repaints only when the tone changes.
class AmbientCanvas extends StatelessWidget {
  const AmbientCanvas({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: CustomPaint(painter: _CanvasPainter(tone, _Dither.image)),
        ),
        child,
      ],
    );
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter(this.tone, this.dither);
  final LightTone tone;
  final ui.Image? dither;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(tone.canvas[0]),
            Color(tone.canvas[1]),
            Color(tone.canvas[2]),
          ],
          stops: const <double>[0, 0.45, 1],
        ).createShader(r),
    );
    if (tone.glowStrength > 0) {
      final double radius = math.max(size.width, size.height) * 0.75;
      final Offset c = Offset(size.width * 0.5, -size.height * 0.08);
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Color(tone.glow).withValues(
                alpha: (tone.dark ? 0.42 : 0.30) * tone.glowStrength,
              ),
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
      old.tone != tone || old.dither != dither;
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
