import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../glass/glass_surface.dart';
import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';
import '../tokens/tokens.dart';

/// "Add light": an [AuraButton] with the plus and the nearby-count badge.
///
/// - Badge: lights nearby that are not added yet. The number rolls up or
///   down when it changes, and its glow breathes when new lights are found
///   (the button glints with it).
class AuraAddButton extends StatefulWidget {
  const AuraAddButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.count = 0,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Lights nearby that can be added; 0 hides the badge.
  final int count;
  final String? semanticsLabel;

  @override
  State<AuraAddButton> createState() => _AuraAddButtonState();
}

class _AuraAddButtonState extends State<AuraAddButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
    value: 1,
  );
  int _found = 0;

  @override
  void didUpdateWidget(AuraAddButton old) {
    super.didUpdateWidget(old);
    // New lights nearby: one glint and one breath of the badge.
    if (widget.count > old.count && !MediaQuery.disableAnimationsOf(context)) {
      _found++;
      _breath.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: <Widget>[
      AuraButton(
        onPressed: widget.onPressed,
        icon: Icons.add_rounded,
        semanticsLabel: widget.semanticsLabel ?? widget.label,
        glintKey: _found,
        glintOnAppear: true,
        child: Text(widget.label),
      ),
      Positioned(
        top: -7,
        right: -5,
        child: NearbyBadge(
          count: widget.count,
          breathe: MediaQuery.disableAnimationsOf(context) ? null : _breath,
        ),
      ),
    ],
  );
}

/// The app's primary action capsule (Add light, Start, Save, Rejoin all…).
///
/// - Dark: real refractive glass ([GlassTier.chrome]) tinted deep navy, with
///   a faint periwinkle glow. Light: soft blue glass with a gentle shadow.
/// - A faint glint travels around the rim every 10 s (and when [glintKey]
///   changes, and when it appears with [glintOnAppear]); at rest nothing animates (no idle
///   frames, see test/perf/idle_activity_test.dart).
/// - Touch: the capsule tilts toward the finger, squeezes slightly and a
///   soft light blooms from the touch point inside the glass. On release
///   it springs back and the bloom spreads out and fades.
/// - Reduce Motion: no glint, tilt or bloom.
///
/// Sizes to its content, or fills a tight width (e.g. a stretched column),
/// with the content centred.
class AuraButton extends StatefulWidget {
  const AuraButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.semanticsLabel,
    this.glintKey = 0,
    this.haptic = HapticEvent.powerOn,
    this.glintOnAppear = false,
  });

  /// Plays the rim glint once when the button first appears (Add light).
  /// Off by default, so sheets and screens with a button are idle at once.
  final bool glintOnAppear;

  final VoidCallback? onPressed;

  /// The label, usually a [Text]; styled in the capsule's ink.
  final Widget child;

  /// Optional leading icon; turns a little while pressed.
  final IconData? icon;
  final String? semanticsLabel;

  /// Changing it replays the rim glint.
  final int glintKey;

  /// Played when the tap completes.
  final HapticEvent haptic;

  @override
  State<AuraButton> createState() => _AuraButtonState();
}

class _AuraButtonState extends State<AuraButton> with TickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
    value: 1,
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 520),
  );
  late final Animation<double> _pressCurve = CurvedAnimation(
    parent: _press,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.elasticIn,
  );
  late final AnimationController _release = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  /// Touch point in the capsule, normalised to -1..1 from its centre.
  Offset _touch = Offset.zero;
  Offset _touchPx = Offset.zero;
  double _width = 200;
  bool _reduceMotion = false;
  bool _greeted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _drift.value = 1;
    } else if (!_greeted) {
      _greeted = true;
      if (widget.glintOnAppear) {
        _drift.forward(from: 0);
      } else {
        _glintLater();
      }
    }
  }

  /// Between glints the button rests (no frames); a covered screen's muted
  /// ticker draws nothing until it is shown again.
  static const Duration _every = Duration(seconds: 10);
  Timer? _next;

  void _glintLater() {
    _next?.cancel();
    _next = Timer(_every, () {
      if (mounted && !_reduceMotion) {
        _drift.forward(from: 0);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _drift.addStatusListener((AnimationStatus st) {
      if (st == AnimationStatus.completed) _glintLater();
    });
  }

  @override
  void didUpdateWidget(AuraButton old) {
    super.didUpdateWidget(old);
    if (widget.glintKey != old.glintKey && !_reduceMotion) {
      _drift.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _next?.cancel();
    _drift.dispose();
    _press.dispose();
    _release.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onPressed != null;

  void _track(Offset local) {
    final Size? s = context.size;
    if (s == null || s.isEmpty) return;
    _touchPx = local;
    _width = s.width;
    _touch = Offset(
      (local.dx / s.width * 2 - 1).clamp(-1.0, 1.0),
      (local.dy / s.height * 2 - 1).clamp(-1.0, 1.0),
    );
  }

  void _down(TapDownDetails d) {
    if (!_enabled) return;
    _track(d.localPosition);
    HapticsScope.of(context).play(HapticEvent.selection);
    _release.value = 0;
    _press.forward();
  }

  void _up() => _press.reverse();

  void _tap() {
    if (!_enabled) return;
    HapticsScope.of(context).play(widget.haptic);
    if (!_reduceMotion) _release.forward(from: 0);
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final PillGlass glass = PillFill.of(dark: dark);
    final IconData? icon = widget.icon;
    // Light: a deep sky-navy that sits softly on the sky-blue glass.
    final Color ink = dark ? Colors.white : const Color(0xFF3A3F47);

    final Widget content = SizedBox(
      height: 48,
      child: Padding(
        padding: EdgeInsets.only(
          left: icon == null ? 24 : 14,
          right: icon == null ? 24 : 20,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              AnimatedBuilder(
                animation: _pressCurve,
                builder: (_, Widget? i) => Transform.rotate(
                  angle: _pressCurve.value * math.pi / 4,
                  child: i,
                ),
                child: Icon(icon, color: ink, size: 22),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: IconTheme.merge(
                  data: IconThemeData(color: ink, size: 20),
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // The glass itself is static; only transforms and overlays animate,
    // so the refraction layer is not rebuilt every frame.
    final Widget body = dark
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              boxShadow: <BoxShadow>[
                // A very soft, faint light glow around the glass.
                const BoxShadow(color: Color(0x0FFFFFFF), blurRadius: 14),
                // Colourless glass: a neutral drop shadow.
                const BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 14,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: GlassSurface(
              tier: GlassTier.chrome,
              radius: 24,
              // Clear, frosted glass that takes the background's colour.
              tint: const Color(0xFF1C1E23),
              liquid: true,
              child: content,
            ),
          )
        : CustomPaint(painter: _LightBodyPainter(glass), child: content);
    final Widget shiny = CustomPaint(
      foregroundPainter: _ShinyRim(dark: dark),
      child: body,
    );

    final Widget capsule = AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_drift, _pressCurve, _release]),
      builder: (BuildContext context, Widget? child) {
        final double p = _pressCurve.value;
        // Wide buttons tilt less, so their ends don't swing far.
        final double tilt = _reduceMotion
            ? 0
            : 0.10 * p * math.min(1.0, 200 / math.max(_width, 1));
        // Squeeze: slightly wider and shorter, like pressing a drop of glass.
        final Matrix4 m = Matrix4.identity()
          ..setEntry(3, 2, 0.0016)
          ..rotateX(-_touch.dy * tilt)
          ..rotateY(_touch.dx * tilt)
          ..scaleByDouble(1 - 0.02 * p, 1 - 0.07 * p, 1, 1);
        return Transform(
          alignment: Alignment.center,
          transform: m,
          child: CustomPaint(
            foregroundPainter: _GlassOverlayPainter(
              drift: _drift.value,
              press: p.clamp(0.0, 1.0),
              release: _release.value,
              touch: _touchPx,
              dark: dark,
            ),
            child: child,
          ),
        );
      },
      child: shiny,
    );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticsLabel,
      excludeSemantics: widget.semanticsLabel != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _down,
        onTapUp: (_) => _up(),
        onTapCancel: _up,
        onTap: _tap,
        child: AnimatedOpacity(
          duration: Motion.fast,
          opacity: _enabled ? 1 : 0.5,
          child: RepaintBoundary(child: capsule),
        ),
      ),
    );
  }
}

/// Light theme body: clear frosted glass (shadow and rim drawn outside).
class _LightBodyPainter extends CustomPainter {
  const _LightBodyPainter(this.glass);

  final PillGlass glass;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    RRect pill(double inset) => RRect.fromRectAndRadius(
      rect.deflate(inset),
      Radius.circular(size.height / 2 - inset),
    );

    // Polished metal bezel, light steel. The base is lighter on top and
    // a little deeper at the bottom; glints and dark reflections are
    // scattered unevenly, different on the top and bottom edges, so no
    // two parts of the rim look the same.
    final RRect rim = pill(1.2);
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xFFDDE0E4),
            Color(0xFFC6C9CE),
            Color(0xFFB9BDC3),
          ],
          stops: <double>[0, 0.55, 1],
        ).createShader(rect),
    );
    void streaks(
      Rect clip,
      List<double> stops,
      List<double> alphas,
      Color tone,
      double width, {
      double blur = 0,
    }) {
      canvas.save();
      canvas.clipRect(clip);
      final Paint paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          colors: <Color>[
            for (final double a in alphas) tone.withValues(alpha: a * tone.a),
          ],
          stops: stops,
        ).createShader(rect);
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(blur, 0.7));
      canvas.drawRRect(rim, paint);
      canvas.restore();
    }

    final Rect top = Rect.fromLTRB(-4, -4, size.width + 4, size.height * 0.5);
    final Rect bottom = Rect.fromLTRB(
      -4,
      size.height * 0.5,
      size.width + 4,
      size.height + 4,
    );
    const Color steel = Color(0x402A2D33); // dark reflections at ~25%
    // Controlled highlights, as from one key light at the top left with
    // a softer fill from the bottom right: a main glint on each edge, one
    // gentle secondary, and two small, soft shadows opposite them.
    streaks(
      top,
      const <double>[0, 0.06, 0.28, 0.42, 0.55, 0.68, 1],
      const <double>[0.7, 1, 0, 0, 0.35, 0, 0],
      Colors.white,
      1.3,
    );
    streaks(
      bottom,
      const <double>[0, 0.24, 0.36, 0.48, 0.7, 0.92, 1],
      const <double>[0, 0, 0.3, 0, 0, 0.9, 0.6],
      Colors.white,
      1.3,
    );
    // Soft bloom around the two main glints.
    streaks(
      top,
      const <double>[0, 0.07, 0.22, 1],
      const <double>[0.45, 0.6, 0, 0],
      Colors.white,
      2.6,
      blur: 1.6,
    );
    streaks(
      bottom,
      const <double>[0, 0.76, 0.92, 1],
      const <double>[0, 0, 0.5, 0.35],
      Colors.white,
      2.6,
      blur: 1.6,
    );
    // Shadows: top right and bottom left only, faint and smooth.
    streaks(
      top,
      const <double>[0, 0.7, 0.85, 1],
      const <double>[0, 0, 0.35, 0.15],
      steel,
      1.1,
    );
    streaks(
      bottom,
      const <double>[0, 0.12, 0.3, 1],
      const <double>[0.2, 0.35, 0, 0],
      steel,
      1.1,
    );

    // Thin bright lip just inside the bezel.
    canvas.drawRRect(
      pill(2.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = const Color(0xB3FFFFFF),
    );

    // Glass body: bright top half, a soft gloss break at the middle, and a
    // light grey lower half catching reflected light.
    final RRect body = pill(3.4);
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xFFFDFDFE),
            Color(0xFFF6F7F9),
            Color(0xFFEEF0F3),
            Color(0xFFF1F2F5),
            Color(0xFFF6F7F9),
          ],
          stops: <double>[0, 0.38, 0.62, 0.85, 1],
        ).createShader(body.outerRect),
    );

    canvas.save();
    canvas.clipRRect(body);
    final double h = size.height;
    final double w = size.width;
    void reflection(Rect r, List<Color> colors, double blur) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)),
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur * 2)
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
          ).createShader(r),
      );
    }

    // Broad, soft reflection of the sky across the top.
    reflection(Rect.fromLTWH(h * 0.28, 3, w - h * 0.56, h * 0.4), <Color>[
      Colors.white.withValues(alpha: 0.75),
      Colors.white.withValues(alpha: 0),
    ], 2.5);
    // Light bouncing up from below, along the bottom.
    reflection(Rect.fromLTWH(h * 0.5, h * 0.66, w - h, h * 0.24), <Color>[
      Colors.white.withValues(alpha: 0),
      Colors.white.withValues(alpha: 0.55),
    ], 3);
    // Two soft diagonal window reflections near the left.
    for (final (double x, double width, double a) in <(double, double, double)>[
      (0.2, 0.06, 0.32),
      (0.29, 0.025, 0.24),
    ]) {
      canvas.save();
      canvas.translate(w * x, 0);
      canvas.skew(-0.45, 0);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w * width, h),
        Paint()
          ..color = Colors.white.withValues(alpha: a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.restore();
    }
    canvas.restore();

    // Sparkle near the top left of the glass.
    final Offset spark = Offset(size.height * 0.62, size.height * 0.2);
    canvas.drawCircle(
      spark,
      4,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: 0.7),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: spark, radius: 4)),
    );
  }

  @override
  bool shouldRepaint(_LightBodyPainter o) => o.glass != glass;
}

/// Rim glint, the touch bloom and the release ripple, clipped to the glass.
class _GlassOverlayPainter extends CustomPainter {
  _GlassOverlayPainter({
    required this.drift,
    required this.press,
    required this.release,
    required this.touch,
    required this.dark,
  });

  final double drift;
  final double press;
  final double release;
  final Offset touch;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect pill = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height / 2),
    );

    // Slow glint drifting around the rim.
    canvas.drawRRect(
      pill.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = SweepGradient(
          transform: GradientRotation(drift * 2 * math.pi),
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(
              alpha: (dark ? 0.40 : 0.85) * math.sin(math.pi * drift),
            ),
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.08, 0.18, 1],
        ).createShader(rect),
    );

    if (press <= 0 && (release <= 0 || release >= 1)) return;

    canvas.save();
    canvas.clipRRect(pill);

    // Held: light gathers under the finger.
    if (press > 0) {
      final double r = 18 + 26 * press;
      canvas.drawCircle(
        touch,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Colors.white.withValues(alpha: (dark ? 0.20 : 0.45) * press),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: touch, radius: r)),
      );
    }

    // Released: the light spreads through the glass and fades.
    if (release > 0 && release < 1) {
      final double e = Curves.easeOutCubic.transform(release);
      final double r = 44 + e * size.width;
      final double fade = 1 - e;
      canvas.drawCircle(
        touch,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: (dark ? 0.16 : 0.30) * fade),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const <double>[0.55, 0.85, 1],
          ).createShader(Rect.fromCircle(center: touch, radius: r)),
      );
      // The rim catches the light as the wave reaches it.
      canvas.drawRRect(
        pill.deflate(0.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(
            alpha: (dark ? 0.35 : 0.6) * math.sin(math.pi * e),
          ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassOverlayPainter o) =>
      o.drift != drift ||
      o.press != press ||
      o.release != release ||
      o.touch != touch ||
      o.dark != dark;
}

/// Lights nearby that are not added yet: a small pill whose number rolls to
/// each new value, with a slow breathing glow while lights are waiting.
class NearbyBadge extends StatefulWidget {
  const NearbyBadge({super.key, required this.count, this.breathe});

  final int count;

  /// A repeating animation that drives the breathing glow; null keeps it
  /// still (Reduce Motion).
  final Animation<double>? breathe;

  @override
  State<NearbyBadge> createState() => _NearbyBadgeState();
}

class _NearbyBadgeState extends State<NearbyBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bump = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
    value: 1,
  );
  bool _up = true;

  @override
  void didUpdateWidget(NearbyBadge old) {
    super.didUpdateWidget(old);
    if (widget.count != old.count) {
      _up = widget.count > old.count;
      if (widget.breathe != null && old.count > 0 && widget.count > 0) {
        _bump.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _bump.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // Light mode: a vivid brand blue (the theme's primary reads dull there).
    final Color base = dark ? scheme.primary : const Color(0xFF3B7BFF);
    final TextStyle digits = TextStyle(
      color: dark ? scheme.onPrimary : Colors.white,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      height: 1,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    final Widget roller = ClipRect(
      child: AnimatedSwitcher(
        duration: Motion.medium,
        switchInCurve: Motion.emphasized,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: Alignment.center,
          children: <Widget>[...previous, ?current],
        ),
        transitionBuilder: (Widget c, Animation<double> a) {
          final bool incoming = c.key == ValueKey<int>(widget.count);
          final double from = (_up ? 1.0 : -1.0) * (incoming ? 1 : -1);
          return SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0, from),
              end: Offset.zero,
            ).animate(a),
            child: FadeTransition(opacity: a, child: c),
          );
        },
        child: Text(
          '${widget.count}',
          key: ValueKey<int>(widget.count),
          style: digits,
        ),
      ),
    );

    final Widget pill = AnimatedBuilder(
      animation: Listenable.merge(<Listenable?>[widget.breathe, _bump]),
      builder: (BuildContext context, Widget? child) {
        final double b = widget.breathe == null
            ? 0.5
            : 0.5 +
                  0.5 *
                      math.sin(widget.breathe!.value * 2 * math.pi * 2) *
                      math.sin(math.pi * widget.breathe!.value);
        final double bump = math.sin(math.pi * _bump.value);
        return Transform.scale(
          scale: 1 + 0.18 * bump,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: base.withValues(alpha: 0.20 + 0.30 * b),
                  blurRadius: 4 + 8 * b,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: AnimatedSize(
        duration: Motion.medium,
        curve: Motion.emphasized,
        child: Container(
          constraints: const BoxConstraints(minWidth: 22),
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color.lerp(base, Colors.white, 0.25)!,
                base,
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: roller,
        ),
      ),
    );

    return ExcludeSemantics(
      child: AnimatedSwitcher(
        duration: Motion.medium,
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (Widget c, Animation<double> a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: a, child: c),
        ),
        child: widget.count <= 0
            ? const SizedBox.shrink(key: ValueKey<bool>(false))
            : KeyedSubtree(key: const ValueKey<bool>(true), child: pill),
      ),
    );
  }
}

/// A crisp, shiny glass edge: bright where light hits (top and bottom
/// right), dim along the sides, plus a faint inner line for thickness.
class _ShinyRim extends CustomPainter {
  const _ShinyRim({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (!dark) return;
    final Rect rect = Offset.zero & size;
    final RRect pill = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height / 2),
    );
    // Key light from the top left: a thin highlight that fades out
    // across the top, plus a weaker bounce at the bottom right.
    canvas.drawRRect(
      pill.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: const Alignment(0.5, 1),
          colors: <Color>[
            Colors.white.withValues(alpha: dark ? 0.55 : 0.95),
            Colors.white.withValues(alpha: dark ? 0.14 : 0.45),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.4, 0.8],
        ).createShader(rect),
    );
    canvas.drawRRect(
      pill.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..shader = LinearGradient(
          begin: const Alignment(0.2, -0.2),
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: dark ? 0.22 : 0.6),
          ],
        ).createShader(rect),
    );
    // Inner line: the glass's thickness.
    canvas.drawRRect(
      pill.deflate(2.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.06 : 0.05,
        ),
    );
    // Outer hairline so the edge reads on any background.
    canvas.drawRRect(
      pill,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = Colors.black.withValues(alpha: dark ? 0.35 : 0.14),
    );
  }

  @override
  bool shouldRepaint(_ShinyRim o) => o.dark != dark;
}
