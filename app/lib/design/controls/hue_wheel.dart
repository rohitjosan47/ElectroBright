import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';

import '../../core/color/hsv.dart';
import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';
import '../tokens/tokens.dart';

export '../../core/color/hsv.dart';

/// Wheel display colour of an [Hsv].
extension HsvDisplay on Hsv {
  Color get color {
    final List<int> c = toRgb8();
    return Color.fromARGB(255, c[0], c[1], c[2]);
  }
}

/// [Hsv] of a displayed colour (keeps [previous] hue for greys).
Hsv hsvOfColor(Color c, {Hsv? previous}) {
  final int argb = c.toARGB32();
  return Hsv.fromRgb8(
    (argb >> 16) & 0xFF,
    (argb >> 8) & 0xFF,
    argb & 0xFF,
    previous: previous,
  );
}

enum _Target { ring, square }

/// Hue ring with an inner saturation/value square (the design chosen in the
/// previous app), rebuilt: responsive, repaint-isolated, a magnifying glass
/// thumb, hue detent haptics and full screen-reader support.
///
/// A touch on the ring or the square is the wheel's at once (a scroll view
/// around it never wins it), and the thumbs follow raw pointer moves; touches
/// anywhere else fall through, so the page still scrolls.
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
  final _WheelArt _art = _WheelArt();
  _Target? _target;
  int? _pointer;
  int _lastHueDetent = -1;
  bool _atEdge = false;

  /// Extra reach around the ring and the square for a finger.
  static const double _ringSlop = 16;
  static const double _squareSlop = 10;

  @override
  void didUpdateWidget(HueWheel old) {
    super.didUpdateWidget(old);
    // Never while a finger is on the wheel: it owns the value then.
    if (_target == null && widget.value != _v.value) {
      _v.value =
          hsvOfColor(widget.value.color, previous: _v.value) ==
              hsvOfColor(_v.value.color, previous: _v.value)
          ? _v
                .value // same colour: keep our (precise) hue
          : widget.value;
    }
  }

  @override
  void dispose() {
    _v.dispose();
    _press.dispose();
    _art.dispose();
    super.dispose();
  }

  static ({double rOut, double rIn, double half}) _geometry(double size) {
    final double rOut = size / 2 - 8;
    final double thickness = size * 0.095;
    final double rIn = rOut - thickness;
    return (rOut: rOut, rIn: rIn, half: (rIn - 10) / math.sqrt2);
  }

  /// What a touch at [p] grabs (null: nothing, let it scroll).
  static _Target? _hit(Offset p, double size) {
    final ({double rOut, double rIn, double half}) g = _geometry(size);
    final Offset d = p - Offset(size / 2, size / 2);
    if (d.dx.abs() <= g.half + _squareSlop &&
        d.dy.abs() <= g.half + _squareSlop) {
      return _Target.square;
    }
    if (d.distance >= g.rIn - _ringSlop && d.distance <= g.rOut + _ringSlop) {
      return _Target.ring;
    }
    return null;
  }

  void _grab(PointerDownEvent e, double size, Haptics h) {
    final _Target? t = _hit(e.localPosition, size);
    if (t == null) return;
    _target = t;
    _pointer = e.pointer;
    h.prepare(HapticEvent.hueDetent);
    _lastHueDetent = (_v.value.h / 30).floor();
    if (Motion.reduced(context)) {
      _press.value = 1;
    } else {
      unawaited(_press.forward());
    }
    widget.onChangeStart?.call();
    _move(e.localPosition, size, h);
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
    _pointer = null;
    _atEdge = false;
    // The lens settles back on a spring.
    if (Motion.reduced(context)) {
      _press.value = 0;
    } else {
      unawaited(
        _press.animateWith(
          SpringSimulation(Motion.snappy, _press.value, 0, _press.velocity),
        ),
      );
    }
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
    final double dpr = MediaQuery.devicePixelRatioOf(context);
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
              // Moves go straight to the thumbs, outside the gesture arena;
              // the recogniser below only claims the pointer and ends it.
              child: Listener(
                onPointerMove: widget.enabled
                    ? (PointerMoveEvent e) {
                        if (e.pointer == _pointer) {
                          _move(e.localPosition, size, h);
                        }
                      }
                    : null,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  excludeFromSemantics: true,
                  gestures: <Type, GestureRecognizerFactory>{
                    if (widget.enabled)
                      _WheelGrab:
                          GestureRecognizerFactoryWithHandlers<_WheelGrab>(
                            () => _WheelGrab(debugOwner: this),
                            (_WheelGrab r) => r
                              ..hits = ((Offset p) => _hit(p, size) != null)
                              ..onGrab = ((PointerDownEvent e) =>
                                  _grab(e, size, h))
                              ..onRelease = _up,
                          ),
                  },
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _WheelPainter(_v, _press, _art, dpr),
                      size: Size.square(size),
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

/// Claims a pointer the moment it lands on the ring or the square (no slop,
/// no waiting for the arena to decide against a scroll view's drag); other
/// touches are not tracked at all and fall through.
class _WheelGrab extends OneSequenceGestureRecognizer {
  _WheelGrab({super.debugOwner});

  bool Function(Offset local)? hits;
  ValueChanged<PointerDownEvent>? onGrab;
  VoidCallback? onRelease;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      super.isPointerAllowed(event) &&
      (hits?.call(event.localPosition) ?? false);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    onGrab?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
      onRelease?.call();
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    onRelease?.call();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'hue wheel grab';
}

/// The wheel's static art: the hue ring and the square's white and black
/// overlays, rastered once per size (the square's hue is a plain fill drawn
/// under the overlays each frame).
final class _WheelArt {
  ui.Image? _image;
  Size? _size;
  double? _dpr;

  ui.Image imageFor(Size size, double dpr) {
    final ui.Image? cached = _image;
    if (cached != null && size == _size && dpr == _dpr) return cached;
    cached?.dispose();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    _paint(Canvas(recorder)..scale(dpr), size);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(
      (size.width * dpr).ceil(),
      (size.height * dpr).ceil(),
    );
    picture.dispose();
    _size = size;
    _dpr = dpr;
    return _image = image;
  }

  void dispose() => _image?.dispose();

  static const List<Color> _spectrum = <Color>[
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  static void _paint(Canvas canvas, Size size) {
    final ({double rOut, double rIn, double half}) g = _HueWheelState._geometry(
      size.width,
    );
    final Offset c = size.center(Offset.zero);
    // Ring (0° = red at 3 o'clock, clockwise).
    canvas.drawCircle(
      c,
      (g.rOut + g.rIn) / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.rOut - g.rIn
        ..shader = const SweepGradient(colors: _spectrum)
            .createShader(Rect.fromCircle(center: c, radius: g.rOut)),
    );
    // Square overlays: white to the left, black to the bottom.
    final Rect sq = _square(c, g.half);
    canvas.save();
    canvas.clipRRect(_rounded(sq));
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
  }

  static Rect _square(Offset c, double half) =>
      Rect.fromCenter(center: c, width: half * 2, height: half * 2);

  static RRect _rounded(Rect sq) =>
      RRect.fromRectAndRadius(sq, const Radius.circular(14));
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.v, this.press, this.art, this.dpr)
    : super(repaint: Listenable.merge(<Listenable>[v, press]));
  final ValueNotifier<Hsv> v;
  final Animation<double> press;
  final _WheelArt art;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final Hsv hsv = v.value;
    final ({double rOut, double rIn, double half}) g = _HueWheelState._geometry(
      size.width,
    );
    final Offset c = size.center(Offset.zero);
    final double ringW = g.rOut - g.rIn;
    final double mid = (g.rOut + g.rIn) / 2;
    final Color hue = HSVColor.fromAHSV(1, hsv.h, 1, 1).toColor();

    // The square's pure hue, under the cached overlays and ring.
    final Rect sq = _WheelArt._square(c, g.half);
    canvas.save();
    canvas.clipRRect(_WheelArt._rounded(sq));
    canvas.drawRect(sq, Paint()..color = hue);
    canvas.restore();
    final ui.Image image = art.imageFor(size, dpr);
    canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, image.width / dpr, image.height / dpr),
      Paint()..filterQuality = FilterQuality.medium,
    );

    final double grow = press.value;
    // Hue thumb on the ring.
    final double a = hsv.h * math.pi / 180;
    _thumb(
      canvas,
      c + Offset(math.cos(a), math.sin(a)) * mid,
      ringW / 2 + 3 + grow * 4,
      hue,
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
    // Soft shadow as a radial falloff (a blur mask filter per frame is
    // costly): about a 4 px Gaussian around a disc of r + 2.
    final double spread = r + 10;
    canvas.drawCircle(
      p,
      spread,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Colors.black.withValues(alpha: 0.30),
            Colors.black.withValues(alpha: 0.30),
            Colors.black.withValues(alpha: 0.25),
            Colors.black.withValues(alpha: 0.15),
            Colors.black.withValues(alpha: 0.05),
            Colors.black.withValues(alpha: 0),
          ],
          stops: <double>[
            0,
            (r - 6) / spread,
            (r - 2) / spread,
            (r + 2) / spread,
            (r + 6) / spread,
            1,
          ],
        ).createShader(Rect.fromCircle(center: p, radius: spread)),
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
  bool shouldRepaint(_WheelPainter old) =>
      old.v != v || old.press != press || old.art != art || old.dpr != dpr;
}
