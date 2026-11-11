import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../glass/glass_surface.dart';
import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';
import '../tokens/tokens.dart';

/// Light theme body: a soft, light candy sky blue.
const Color _skyTop = Color(0xFFE8F5FF);
const Color _skyBottom = Color(0xFFCBE7FC);

/// Deep navy that tints the dark theme's liquid glass.
const Color _darkGlassTint = Color(0xFF1F2B48);

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
    final Color ink = dark ? glass.ink : const Color(0xFF1E3A5F);

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
                BoxShadow(
                  color: glass.halo.withValues(alpha: 0.18),
                  blurRadius: 18,
                ),
                const BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: GlassSurface(
              tier: GlassTier.chrome,
              radius: 24,
              tint: _darkGlassTint,
              child: content,
            ),
          )
        : CustomPaint(painter: _LightBodyPainter(glass), child: content);

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
      child: body,
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

/// Light theme body: soft blue glass with a top highlight (no shadow).
class _LightBodyPainter extends CustomPainter {
  const _LightBodyPainter(this.glass);

  final PillGlass glass;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect pill = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(
      pill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Light candy sky blue, a touch deeper at the bottom.
          colors: <Color>[_skyTop, _skyBottom],
        ).createShader(rect),
    );
    canvas.drawRRect(
      pill.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = glass.halo.withValues(alpha: 0.10),
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
    final TextStyle digits = TextStyle(
      color: scheme.onPrimary,
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
                  color: scheme.primary.withValues(alpha: 0.20 + 0.30 * b),
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
                Color.lerp(scheme.primary, Colors.white, 0.25)!,
                scheme.primary,
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
