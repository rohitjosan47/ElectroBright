import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';

import '../../core/color/light_surfaces.dart';

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
    this.height = 44,
    this.leading,
    this.leadingBuilder,
    this.trailing,
    this.trailingBuilder,
    this.valueText,
    this.enabled = true,
    this.glassTier = GlassTier.panel,
    this.elevated = true,
    super.key,
  }) : assert(trailing == null || trailingBuilder == null),
       assert(leading == null || leadingBuilder == null);

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// Colours painted along the whole track (gradient sliders).
  final List<Color>? track;

  final double height;
  final Widget? leading;
  final Widget? trailing;

  /// Leading widget that follows the shown value (finger, spring), given the
  /// track [width] too (e.g. to read well over the fill or the empty track).
  /// Rebuilt only when [valueText] of the value changes.
  final Widget Function(double value, double width)? leadingBuilder;

  /// Trailing widget that follows the shown value (finger, spring). Rebuilt
  /// only when [valueText] of the value changes, e.g. per whole percent.
  final Widget Function(double value, double width)? trailingBuilder;
  final String semanticLabel;
  final String Function(double value)? valueText;
  final bool enabled;

  /// The glass of the track (chrome = real refraction, for a slider floating
  /// on the canvas; panel for sliders inside panels).
  final GlassTier glassTier;

  /// Casts the track's drop shadow (off inside a panel, see
  /// [GlassSurface.elevated]).
  final bool elevated;

  /// Gradient sliders: the gradient's inset from the track and the knob's
  /// from the gradient. Track, gradient and knob are concentric at each end,
  /// evenly spaced, and the knob's shadow stays on the gradient.
  static const double gradientInset = 3;

  /// The knob of a gradient slider of [size] at [fraction].
  static ({Offset centre, double radius}) gradientKnob(
    Size size,
    double fraction,
  ) {
    final double end = size.height / 2;
    return (
      centre: Offset(
        end + fraction.clamp(0.0, 1.0) * (size.width - 2 * end),
        end,
      ),
      radius: end - 2 * gradientInset,
    );
  }

  /// Pill sliders: how far the fill sits inside the track (the glass rim's
  /// width plus a hair), on every side.
  static const double fillInset = 2;

  /// Pill slider fill geometry for a track of [size] at [fraction]: the
  /// inner tube (the track inset on every side, concentric radius) and the
  /// fill body inside it (leading end rounded min(h/2, w/2)); null when
  /// empty.
  static ({RRect tube, RRect body})? fillShapes(Size size, double fraction) {
    const double inset = fillInset;
    final double h = size.height - 2 * inset;
    final double w = fraction.clamp(0.0, 1.0) * (size.width - 2 * inset);
    if (w <= 0 || h <= 0) return null;
    final Radius end = Radius.circular(math.min(h / 2, w / 2));
    return (
      tube: RRect.fromRectAndRadius(
        Rect.fromLTWH(inset, inset, size.width - 2 * inset, h),
        Radius.circular(h / 2),
      ),
      body: RRect.fromRectAndCorners(
        Rect.fromLTWH(inset, inset, w, h),
        topRight: end,
        bottomRight: end,
      ),
    );
  }

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
    // Light or dark only: the slider never follows the light's colour.
    final bool dark = ToneScope.darkOf(context);
    final Haptics h = HapticsScope.of(context);
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
      child: _body(context, dark, h),
    );
  }

  Widget _body(BuildContext context, bool dark, Haptics h) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        Widget? follow(
          Widget Function(double value, double width)? builder,
          Widget? fixed,
        ) => builder == null
            ? fixed
            : ValueListenableBuilder<String>(
                valueListenable: _shown,
                builder: (BuildContext context, _, _) =>
                    builder(_v.value, width),
              );
        final Widget? leading = follow(widget.leadingBuilder, widget.leading);
        final Widget? trailing = follow(
          widget.trailingBuilder,
          widget.trailing,
        );
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
                tier: widget.glassTier,
                radius: Radii.capsule,
                elevated: widget.elevated,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _TrackPainter(
                      value: _v,
                      min: widget.min,
                      max: widget.max,
                      track: widget.track,
                      dark: dark,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        // Pill sliders: the fill is water in the tube.
                        if (widget.track == null)
                          _WaterFill(
                            value: _v,
                            min: widget.min,
                            max: widget.max,
                            dark: dark,
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.m,
                          ),
                          child: Row(
                            children: <Widget>[
                              // At large text sizes the label shrinks to fit the
                              // pill instead of overflowing it.
                              Expanded(
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: leading == null
                                      ? null
                                      : FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: leading,
                                        ),
                                ),
                              ),
                              if (trailing != null) ...<Widget>[
                                const SizedBox(width: Space.s),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: trailing,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
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
    required this.track,
    required this.dark,
  }) : super(repaint: value);

  final ValueListenable<double> value;
  final double min;
  final double max;
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
      // Gradient slider: the whole track shows the range, a glass knob rides
      // it. The gradient is inset from the track and the knob from the
      // gradient by the same step, all concentric at the ends, so no edge
      // runs into another and nothing reaches the track's rim.
      const double g = GlassSlider.gradientInset;
      canvas.drawRRect(
        shape.deflate(g),
        Paint()
          ..shader = LinearGradient(colors: t).createShader(Offset.zero & size),
      );
      final (:Offset centre, :double radius) = GlassSlider.gradientKnob(
        size,
        fraction,
      );
      final Offset c = centre;
      final double r = radius;
      // A soft shadow under the knob, ending at the gradient's edge.
      final Offset below = c + const Offset(0, 1);
      final double reach = r + g - 1;
      canvas.drawCircle(
        below,
        reach,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Colors.black.withValues(alpha: dark ? 0.35 : 0.18),
              Colors.black.withValues(alpha: 0),
            ],
            stops: <double>[r / reach, 1],
          ).createShader(Rect.fromCircle(center: below, radius: reach)),
      );
      canvas.drawCircle(c, r, Paint()..color = Colors.white);
      if (!dark) {
        // A crisp dark outline keeps the knob visible on light gradients.
        canvas.drawCircle(
          c,
          r - 0.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.black.withValues(alpha: 0.35),
        );
      }
      canvas.drawCircle(
        c,
        r - 3,
        Paint()..color = Color.lerp(t.first, t.last, fraction)!,
      );
    } else {
      // Pill slider: the empty tube (the water in it is [_WaterFill], a
      // refracting lens above this painter).
      final PillGlass glass = PillFill.of(dark: dark);
      if (!dark) {
        // A faint neutral tint so the empty track reads as glass.
        canvas.drawRRect(
          shape,
          Paint()
            ..color = Colors.black.withValues(alpha: LightSurfaces.trackAlpha),
        );
      }
      final ({RRect tube, RRect body})? shapes = GlassSlider.fillShapes(
        size,
        fraction,
      );
      if (shapes != null) {
        // Around the water, inside the track: dark a faint periwinkle glow,
        // light a soft bluish shadow (never grey). Only outside the water:
        // it is transparent, and a halo beneath would cloud it.
        canvas.save();
        canvas.clipPath(
          Path.combine(
            PathOperation.difference,
            Path()..addRRect(shape),
            Path()..addRRect(shapes.body),
          ),
        );
        canvas.drawRRect(
          dark ? shapes.body : shapes.body.shift(const Offset(0, 1)),
          Paint()
            ..color = glass.halo.withValues(alpha: dark ? 0.34 : 0.26)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, dark ? 6 : 2.5),
        );
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.track != track ||
      old.dark != dark;
}

/// A pill slider's fill: clear, colourless water in the glass tube, following the value
/// (inset and concentric, shrinking smoothly to nothing; see
/// [GlassSlider.fillShapes]). A real refracting lens (water's refractive
/// index, a hint of dispersion, Fresnel edges) under painted light cues
/// ([_WaterPainter]). Solid under Reduce Transparency; without refraction
/// (route transitions, the kill switch) the cues alone.
class _WaterFill extends StatelessWidget {
  const _WaterFill({
    required this.value,
    required this.min,
    required this.max,
    required this.dark,
  });

  final ValueListenable<double> value;
  final double min;
  final double max;
  final bool dark;

  /// Clear water: no tint, no whitening, the background's own saturation
  /// (it takes whatever colour is behind it), water's refractive index, a
  /// hint of dispersion and Fresnel edges.
  static LiquidGlassSettings _water({required bool dark}) =>
      LiquidGlassSettings(
        glassColor: const Color(0x00FFFFFF),
        thickness: 24,
        blur: 1,
        refractiveIndex: 1.33,
        chromaticAberration: 0.03,
        lightIntensity: dark ? 0.7 : 1,
        fresnelStrength: dark ? 1.05 : 1.4,
        saturation: 1,
      );

  @override
  Widget build(BuildContext context) {
    final GlassPolicy? policy = GlassPolicy.maybeOf(context);
    final PillGlass g = PillFill.of(dark: dark);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Size size = box.biggest;
        return ValueListenableBuilder<double>(
          valueListenable: value,
          builder: (BuildContext context, double v, _) {
            final double fraction = ((v - min) / (max - min)).clamp(0.0, 1.0);
            final ({RRect tube, RRect body})? shapes = GlassSlider.fillShapes(
              size,
              fraction,
            );
            if (shapes == null) return const SizedBox.shrink();
            final Rect r = shapes.body.outerRect;
            final double radius = math.min(r.height / 2, r.width / 2);
            final Widget cues = CustomPaint(
              painter: _WaterPainter(glass: g, dark: dark, radius: radius),
              child: const SizedBox.expand(),
            );
            final Widget water = (policy?.solid ?? false)
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: g.solid,
                      borderRadius: BorderRadius.circular(radius),
                    ),
                  )
                : !(policy?.refraction ?? true)
                ? cues
                : GlassContainer(
                    shape: LiquidRoundedRectangle(borderRadius: radius),
                    useOwnLayer: true,
                    settings: _water(dark: dark),
                    child: cues,
                  );
            return ClipRRect(
              clipper: _RRectClip(shapes.tube),
              child: Stack(
                children: <Widget>[
                  Positioned.fromRect(
                    key: const ValueKey<String>('pill-water'),
                    rect: r,
                    child: water,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _RRectClip extends CustomClipper<RRect> {
  const _RRectClip(this.rrect);
  final RRect rrect;
  @override
  RRect getClip(Size size) => rrect;
  @override
  bool shouldReclip(_RRectClip old) => old.rrect != rrect;
}

/// The light on the water (it has no colour of its own): the meniscus along
/// the top, a glint, a bright crescent where the leading end curves, a faint
/// internal reflection along the bottom and Fresnel-bright edges. Everything bright
/// stays above or below the band the icon and label sit in (30-70 % of the
/// height), so their ink keeps its contrast.
class _WaterPainter extends CustomPainter {
  const _WaterPainter({
    required this.glass,
    required this.dark,
    required this.radius,
  });

  final PillGlass glass;
  final bool dark;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final Rect rect = Offset.zero & size;
    final RRect body = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(body);
    if (!dark) {
      // Light: a little luminance, neutral (the background keeps its own
      // colour; the navy ink only gains).
      canvas.drawRRect(
        body,
        Paint()..color = Colors.white.withValues(alpha: 0.1),
      );
    } else {
      // Dark: a faint soft glow just inside the edge.
      canvas.drawRRect(
        body.deflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = Colors.white.withValues(alpha: 0.05)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    if (!dark) {
      // Light: the water's thicker edge, a faint neutral shading just inside
      // it (colourless, so the background keeps its own colour), gives the
      // body a little more definition against the light track.
      canvas.drawRRect(
        body.deflate(2.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = Colors.black.withValues(alpha: 0.09)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    // Internal reflection along the bottom.
    canvas.drawRRect(
      body.deflate(1.2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: dark ? 0.22 : 0.4),
          ],
          stops: const <double>[0, 0.8, 1],
        ).createShader(rect),
    );
    // The meniscus: a bright line hugging the top edge, softly haloed,
    // fading towards both ends.
    final double m = dark ? 0.62 : 0.95;
    final Shader fade = LinearGradient(
      colors: <Color>[
        Colors.white.withValues(alpha: 0.2 * m),
        Colors.white.withValues(alpha: m),
        Colors.white.withValues(alpha: m),
        Colors.white.withValues(alpha: 0.35 * m),
      ],
      stops: const <double>[0, 0.18, 0.8, 1],
    ).createShader(rect);
    final Rect top = Rect.fromLTWH(0, 0, w, h * 0.22);
    canvas.save();
    canvas.clipRect(top);
    canvas.drawRRect(
      body.deflate(dark ? 1.4 : 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dark ? 2 : 4
        ..shader = fade
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, dark ? 1.3 : 2.5),
    );
    // Dark: the line sits closer to the rim, so the bright border is a
    // little narrower.
    canvas.drawRRect(
      body.deflate(dark ? 0.8 : 1.1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dark ? 0.9 : 1.2
        ..shader = fade,
    );
    canvas.restore();
    // A glint: the light source reflected near the top of the leading end.
    if (w > h * 1.4) {
      final Rect glint = Rect.fromCenter(
        center: Offset(w - h * 0.95, h * 0.2),
        width: h * 0.9,
        height: h * 0.11,
      );
      canvas.drawOval(
        glint,
        Paint()
          ..color = Colors.white.withValues(alpha: dark ? 0.62 : 0.9)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
      );
    }
    // The curved leading end catches the light: a thin bright crescent.
    if (w > h * 0.6) {
      final Rect cap = Rect.fromLTWH(
        w - 2 * radius,
        0,
        2 * radius,
        h,
      ).deflate(1.2);
      canvas.drawArc(
        cap,
        -math.pi / 3,
        math.pi * 2 / 3,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = dark ? 1.15 : 1.5
          ..color = Colors.white.withValues(alpha: dark ? 0.45 : 0.75)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
      );
    }
    // Fresnel: the water's edges catch more light than its middle.
    canvas.drawRRect(
      body.deflate(dark ? 0.4 : 0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dark ? 0.75 : 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: dark ? 0.6 : 0.9),
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.08),
            (dark ? Colors.white : glass.halo).withValues(
              alpha: dark ? 0.3 : 0.36,
            ),
          ],
          stops: const <double>[0, 0.4, 0.6, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WaterPainter old) =>
      old.glass != glass || old.dark != dark || old.radius != radius;
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
