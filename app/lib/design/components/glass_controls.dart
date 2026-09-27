import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../core/color/light_surfaces.dart';
import '../../core/color/light_tone.dart';
import '../../core/protocol/eb/mode_catalog.dart';
import '../glass/glass_surface.dart';
import '../haptics/haptics.dart';
import '../haptics/haptics_scope.dart';
import '../tokens/tokens.dart';
import '../tone/tone_scope.dart';
import 'mode_glyph.dart';

/// A round glass button (chrome tier): scales down on press, with haptics.
class GlassIconButton extends StatefulWidget {
  const GlassIconButton({
    required this.icon,
    required this.onPressed,
    required this.label,
    this.size = 44,
    this.active = false,
    this.haptic = HapticEvent.selection,
    this.tier = GlassTier.chrome,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String label;
  final double size;

  /// Lit in the light's accent (e.g. the power button while on).
  final bool active;
  final HapticEvent haptic;
  final GlassTier tier;

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    // The palette only matters when lit; otherwise light/dark is enough, so
    // the glass is not rebuilt while the light's colour glides.
    final LightTone? tone = widget.active ? ToneScope.of(context) : null;
    final bool dark = ToneScope.darkOf(context);
    final Haptics h = HapticsScope.of(context);
    final bool enabled = widget.onPressed != null;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: enabled
            ? (_) {
                h.prepare(widget.haptic);
                setState(() => _down = true);
              }
            : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: enabled
            ? (_) {
                setState(() => _down = false);
                h.play(widget.haptic);
                widget.onPressed!();
              }
            : null,
        child: AnimatedScale(
          scale: _down ? 0.9 : 1,
          duration: Motion.fast,
          curve: Motion.emphasized,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: SizedBox.square(
              dimension: widget.size,
              // Lit: glass tinted in the light's accent, with its glow;
              // the icon keeps the theme's colour so it reads on both.
              child: tone != null && !dark
                  // Light: glass tinted in the light's luminous colour,
                  // shining onto the surface below; the icon in whichever
                  // ink reads on it (>= 4.5:1).
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Color(LightSurfaces(tone).glow)
                                .withValues(alpha: 0.55),
                            blurRadius: 16,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: GlassSurface(
                        tier: widget.tier,
                        radius: widget.size / 2,
                        tint: Color(LightSurfaces(tone).activeTint),
                        child: Center(
                          child: Icon(
                            widget.icon,
                            color: Color(LightSurfaces(tone).activeIcon),
                            size: widget.size * 0.48,
                          ),
                        ),
                      ),
                    )
                  : tone != null
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Color(tone.glow).withValues(alpha: 0.45),
                            blurRadius: 16,
                          ),
                        ],
                      ),
                      child: GlassSurface(
                        tier: widget.tier,
                        radius: widget.size / 2,
                        tint: Color(tone.accent),
                        child: Center(
                          child: Icon(
                            widget.icon,
                            color: fg,
                            size: widget.size * 0.48,
                          ),
                        ),
                      ),
                    )
                  : GlassSurface(
                      tier: widget.tier,
                      radius: widget.size / 2,
                      tinted: false,
                      child: Center(
                        child: Icon(
                          widget.icon,
                          color: fg,
                          size: widget.size * 0.48,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented control with a glass thumb that slides on a liquid spring.
/// The thumb always stays inside its track: inset by [inset], concentric
/// with it, stretched by its speed and squashed against an end, never past
/// it (nothing is clipped).
class GlassSegmented<T> extends StatefulWidget {
  const GlassSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.thumbTier = GlassTier.chrome,
    this.elevated = true,
    super.key,
  });

  static const double height = 44;

  /// Track padding around the thumb.
  static const double inset = 3;

  /// Corner radii: the track a capsule, the thumb concentric inside it.
  static const double trackRadius = height / 2;
  static const double thumbRadius = trackRadius - inset;

  /// The thumb inside a track's inner box of [inner] width for spring
  /// position [x] (in segments) at [velocity] (segments/s): widened by its
  /// speed (liquid stretch); past an end its far edge stops there and the
  /// thumb squashes instead of moving on.
  @visibleForTesting
  static ({double left, double right}) thumbSpan({
    required double x,
    required double velocity,
    required int n,
    required double inner,
  }) {
    final double w = inner / n;
    final double stretch = (velocity.abs() * 0.06).clamp(0.0, 0.35) * w;
    final double narrowest = math.min(w, math.max(w * 0.7, height));
    final double left = (x * w - stretch / 2).clamp(0.0, inner - narrowest);
    final double right = (x * w + w + stretch / 2).clamp(
      left + narrowest,
      inner,
    );
    return (left: left, right: right);
  }

  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Real refraction by default; the control screen can afford up to seven
  /// chrome surfaces (measured on device), panel tier is for denser screens.
  final GlassTier thumbTier;

  /// Casts the track's drop shadow (off inside a panel, see
  /// [GlassSurface.elevated]).
  final bool elevated;

  @override
  State<GlassSegmented<T>> createState() => _GlassSegmentedState<T>();
}

class _GlassSegmentedState<T> extends State<GlassSegmented<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _x = AnimationController.unbounded(vsync: this)
    ..value = _index.toDouble();

  int get _index => math.max(
    0,
    widget.segments.indexWhere(((T, String) s) => s.$1 == widget.selected),
  );

  @override
  void didUpdateWidget(GlassSegmented<T> old) {
    super.didUpdateWidget(old);
    final double target = _index.toDouble();
    if (_x.value == target) return;
    if (Motion.reduced(context)) {
      _x.value = target;
    } else {
      unawaited(
        _x
            .animateWith(
              SpringSimulation(Motion.liquid, _x.value, target, _x.velocity),
            )
            // Rest exactly on the segment (the spring stops within
            // tolerance, a hair squashed against an end).
            .then((_) => _x.value = target),
      );
    }
  }

  @override
  void dispose() {
    _x.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = ToneScope.darkOf(context);
    final Haptics h = HapticsScope.of(context);
    final int n = widget.segments.length;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    return SizedBox(
      height: GlassSegmented.height,
      child: GlassSurface(
        radius: GlassSegmented.trackRadius,
        padding: const EdgeInsets.all(GlassSegmented.inset),
        elevated: widget.elevated,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // No thumb while no segment is selected (e.g. lights that
                // differ).
                if (widget.segments.any(
                  ((T, String) s) => s.$1 == widget.selected,
                ))
                  AnimatedBuilder(
                    animation: _x,
                    builder: (BuildContext context, _) {
                      final ({double left, double right}) span =
                          GlassSegmented.thumbSpan(
                            x: _x.value,
                            velocity: _x.velocity,
                            n: n,
                            inner: c.maxWidth,
                          );
                      return Positioned(
                        left: span.left,
                        width: span.right - span.left,
                        top: 0,
                        bottom: 0,
                        // Its edge is the glass's own rim (no border), and it
                        // casts no shadow outside itself.
                        child: GlassSurface(
                          tier: widget.thumbTier,
                          radius: GlassSegmented.thumbRadius,
                          tinted: false,
                          elevated: false,
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                Row(
                  children: <Widget>[
                    for (final (T value, String label) in widget.segments)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: value == widget.selected,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (value == widget.selected) return;
                              h.play(HapticEvent.selection);
                              widget.onChanged(value);
                            },
                            child: Center(
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: fg.withValues(
                                    alpha: value == widget.selected
                                        ? 1
                                        : LightSurfaces.dim(0.65, dark: dark),
                                  ),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The frame of a choice (effect tile, Solid Color row, preset slot): the
/// accent border and glow at [selection] 0..1.
ShapeDecoration modeSelectionFrame(LightTone tone, double selection) {
  final double t = selection.clamp(0.0, 1.0);
  if (!tone.dark) {
    // Light: a fine edge in a deeper shade of the light's hue (>= 3:1 on the
    // tile), the light's colour shining onto the surface below, and a small
    // neutral contact shadow for lift.
    final LightSurfaces light = LightSurfaces(tone);
    return ShapeDecoration(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        side: BorderSide(
          color: Color(light.accentBorder).withValues(alpha: t),
          width: 1.5,
        ),
      ),
      shadows: t == 0
          ? const <BoxShadow>[]
          : <BoxShadow>[
              BoxShadow(
                color: Color(light.glow).withValues(alpha: 0.45 * t),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08 * t),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
    );
  }
  return ShapeDecoration(
    shape: RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(Radii.medium),
      side: BorderSide(
        color: Color(tone.accent).withValues(alpha: t),
        width: 2,
      ),
    ),
    shadows: t == 0
        ? const <BoxShadow>[]
        : <BoxShadow>[
            BoxShadow(
              color: Color(tone.glow).withValues(alpha: 0.35 * t),
              blurRadius: 20,
            ),
          ],
  );
}

/// One of several choices (effect tile, Solid Color row, preset slot), all
/// moving alike: the frame lights up on a [Motion.snappy] spring when
/// [selected], the surface presses in under the finger and springs back,
/// and each increment of [pulse] plays a short [Motion.bouncy] success
/// bump. Under Reduce Motion nothing moves; the frame only fades.
class ChoiceFrame extends StatefulWidget {
  const ChoiceFrame({
    required this.selected,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pulse = 0,
    super.key,
  });

  final bool selected;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final int pulse;

  @override
  State<ChoiceFrame> createState() => _ChoiceFrameState();
}

class _ChoiceFrameState extends State<ChoiceFrame>
    with TickerProviderStateMixin {
  late final AnimationController _selection = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );

  /// 0 = up, 1 = pressed in.
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );

  /// Extra scale of the success bump (0 at rest).
  late final AnimationController _pulse = AnimationController.unbounded(
    vsync: this,
  );

  static const double _pressedScale = 0.96;

  /// Initial speed that peaks the bump at about +4 % on Motion.bouncy.
  static const double _pulseVelocity = 1.36;

  late final Listenable _motion = Listenable.merge(<Listenable>[
    _selection,
    _press,
    _pulse,
  ]);

  @override
  void didUpdateWidget(ChoiceFrame old) {
    super.didUpdateWidget(old);
    if (widget.selected != old.selected) {
      unawaited(
        _selection.animateWith(
          SpringSimulation(
            Motion.snappy,
            _selection.value,
            widget.selected ? 1 : 0,
            _selection.velocity,
          ),
        ),
      );
    }
    if (widget.pulse > old.pulse && !Motion.reduced(context)) {
      _pulse.value = 0;
      unawaited(
        _pulse.animateWith(
          SpringSimulation(Motion.bouncy, 0, 0, _pulseVelocity),
        ),
      );
    }
  }

  void _pressTo(double to) {
    if (Motion.reduced(context)) return;
    unawaited(
      _press.animateWith(
        SpringSimulation(Motion.snappy, _press.value, to, _press.velocity),
      ),
    );
  }

  @override
  void dispose() {
    _selection.dispose();
    _press.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final bool pressable = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      onTapDown: pressable ? (_) => _pressTo(1) : null,
      onTapUp: pressable ? (_) => _pressTo(0) : null,
      onTapCancel: pressable ? () => _pressTo(0) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _pressTo(0);
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _motion,
        child: widget.child,
        builder: (BuildContext context, Widget? child) => Transform.scale(
          scale:
              (1 - (1 - _pressedScale) * _press.value.clamp(0.0, 1.0)) *
              (1 + _pulse.value),
          child: DecoratedBox(
            decoration: modeSelectionFrame(tone, _selection.value),
            // Inside the 2 px border, as a decorated container lays it out.
            child: Padding(padding: const EdgeInsets.all(2), child: child),
          ),
        ),
      ),
    );
  }
}

/// A lighting-mode tile: animated glyph, name, lit when active.
class ModeTile extends StatelessWidget {
  const ModeTile({
    required this.spec,
    required this.selected,
    required this.onTap,
    required this.color,
    this.animate = true,
    this.badge,
    super.key,
  });

  final EbModeSpec spec;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
  final bool animate;

  /// A short note in the corner (e.g. "3/5": how many lights have it).
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final Haptics h = HapticsScope.of(context);
    final List<Color> palette = <Color>[
      for (final int c in spec.gradient) Color(c),
    ];
    final bool own = spec.colorUse == EbColorUse.never;
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    return Semantics(
      button: true,
      selected: selected,
      label: spec.name,
      hint: spec.description,
      child: ChoiceFrame(
        selected: selected,
        onTap: () {
          h.play(HapticEvent.selection);
          onTap();
        },
        child: GlassSurface(
          radius: Radii.medium,
          liquid: true,
          padding: const EdgeInsets.all(Space.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _Badged(
                  badge: badge,
                  fg: fg,
                  child: ModeGlyph(
                    glyph: spec.glyph,
                    color: own ? palette.first : color,
                    palette: palette,
                    animate: animate,
                  ),
                ),
              ),
              const SizedBox(height: Space.xs),
              Text(
                spec.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [child] with [badge] (if any) in its top-right corner.
class _Badged extends StatelessWidget {
  const _Badged({required this.badge, required this.fg, required this.child});
  final String? badge;
  final Color fg;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final String? b = badge;
    if (b == null) return child;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        Align(
          alignment: Alignment.topRight,
          child: Text(
            b,
            style: TextStyle(
              color: fg.withValues(
                alpha: LightSurfaces.dim(0.7, dark: fg == Colors.white),
              ),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// The hero "light orb": what the light is doing right now. A new effect
/// crossfades in (its glyph growing into place); a new colour does not.
class LightOrb extends StatelessWidget {
  const LightOrb({
    required this.spec,
    required this.color,
    required this.on,
    this.level,
    this.size = 180,
    this.speed = 1,
    super.key,
  });

  final EbModeSpec spec;
  final Color color;
  final bool on;

  /// The light's brightness as it glides (0..1): the orb's intensity follows
  /// it at paint time. Without it the orb is simply lit or dimmed by [on].
  final Animation<double>? level;
  final double size;
  final double speed;

  static final Animatable<double> _intensity = Tween<double>(
    begin: 0.18,
    end: 1,
  );

  @override
  Widget build(BuildContext context) {
    final List<Color> palette = <Color>[
      for (final int c in spec.gradient) Color(c),
    ];
    final Animation<double>? level = this.level;
    Widget dim(Widget child) => level != null
        ? FadeTransition(opacity: _intensity.animate(level), child: child)
        : AnimatedOpacity(
            opacity: on ? 1 : 0.18,
            duration: Motion.medium,
            child: child,
          );
    return Semantics(
      image: true,
      label: on ? '${spec.name}, on' : 'Off',
      child: SizedBox.square(
        dimension: size,
        child: dim(
          GlyphSwitcher(
            glyph: spec.glyph,
            child: ModeGlyph(
              glyph: spec.glyph,
              color: spec.colorUse == EbColorUse.never ? palette.first : color,
              palette: palette,
              animate: on,
              speed: speed,
            ),
          ),
        ),
      ),
    );
  }
}

/// Crossfades [child] when [glyph] changes, the new one growing from 0.92 on
/// a [Motion.smooth] spring. Keyed by the glyph alone: a new [child] for the
/// same glyph (another colour or speed) updates in place.
class GlyphSwitcher extends StatefulWidget {
  const GlyphSwitcher({required this.glyph, required this.child, super.key});

  final Object glyph;
  final Widget child;

  @override
  State<GlyphSwitcher> createState() => _GlyphSwitcherState();
}

class _GlyphSwitcherState extends State<GlyphSwitcher>
    with TickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: 1,
  )..addStatusListener(_onFade);
  late final Animation<double> _fadeIn = CurvedAnimation(
    parent: _fade,
    curve: Motion.emphasized,
  );
  late final Animation<double> _fadeOut = ReverseAnimation(_fadeIn);
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  static const Animation<double> _still = AlwaysStoppedAnimation<double>(1);

  Object? _oldGlyph;
  Widget? _oldChild;

  void _onFade(AnimationStatus s) {
    if (s == AnimationStatus.completed && _oldChild != null) {
      setState(() => _oldChild = _oldGlyph = null);
    }
  }

  @override
  void didUpdateWidget(GlyphSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.glyph == old.glyph) return;
    if (Motion.reduced(context)) {
      _oldChild = _oldGlyph = null;
      _fade.value = 1;
      _scale.value = 1;
      return;
    }
    _oldGlyph = old.glyph;
    _oldChild = old.child;
    unawaited(_fade.forward(from: 0));
    _scale.value = 0.92;
    unawaited(_scale.animateWith(SpringSimulation(Motion.smooth, 0.92, 1, 0)));
  }

  @override
  void dispose() {
    _fade.dispose();
    _scale.dispose();
    super.dispose();
  }

  // Both layers have the same shape, so the outgoing glyph keeps its state.
  Widget _layer(
    Object glyph,
    Animation<double> opacity,
    Animation<double> scale,
    Widget child,
  ) => KeyedSubtree(
    key: ValueKey<Object>(glyph),
    child: FadeTransition(
      opacity: opacity,
      child: ScaleTransition(scale: scale, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final Widget? old = _oldChild;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (old != null) _layer(_oldGlyph!, _fadeOut, _still, old),
        _layer(
          widget.glyph,
          old == null ? _still : _fadeIn,
          _scale,
          widget.child,
        ),
      ],
    );
  }
}

/// Circular dial for the sleep timer, with detents on each step.
class TimerDial extends StatefulWidget {
  const TimerDial({
    required this.steps,
    required this.index,
    required this.onChanged,
    required this.label,
    this.progress,
    super.key,
  });

  /// Selectable durations.
  final List<Duration> steps;
  final int index;
  final ValueChanged<int> onChanged;
  final String Function(Duration d) label;

  /// Running countdown 0..1 (null = not running).
  final double? progress;

  @override
  State<TimerDial> createState() => _TimerDialState();
}

class _TimerDialState extends State<TimerDial> {
  void _drag(Offset p, Size size, Haptics h) {
    final Offset d = p - size.center(Offset.zero);
    double a = math.atan2(d.dx, -d.dy); // 0 at 12 o'clock, clockwise
    if (a < 0) a += 2 * math.pi;
    final int i = (a / (2 * math.pi) * widget.steps.length).floor().clamp(
      0,
      widget.steps.length - 1,
    );
    if (i != widget.index) {
      h.play(HapticEvent.detent);
      widget.onChanged(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final Haptics h = HapticsScope.of(context);
    final Color fg = tone.dark ? Colors.white : const Color(0xFF15171C);
    // Counting down: a read-only ring, no longer a picker.
    final bool running = widget.progress != null;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double s = math.min(c.maxWidth, 260);
        final Size size = Size.square(s);
        return Semantics(
          slider: !running,
          label: 'Sleep timer',
          value: widget.label(widget.steps[widget.index]),
          increasedValue: widget.label(
            widget.steps[math.min(widget.index + 1, widget.steps.length - 1)],
          ),
          decreasedValue: widget.label(
            widget.steps[math.max(widget.index - 1, 0)],
          ),
          readOnly: running,
          onIncrease: !running && widget.index < widget.steps.length - 1
              ? () => widget.onChanged(widget.index + 1)
              : null,
          onDecrease: !running && widget.index > 0
              ? () => widget.onChanged(widget.index - 1)
              : null,
          child: GestureDetector(
            onPanDown: running
                ? null
                : (DragDownDetails d) => _drag(d.localPosition, size, h),
            onPanUpdate: running
                ? null
                : (DragUpdateDetails d) => _drag(d.localPosition, size, h),
            child: SizedBox.fromSize(
              size: size,
              child: CustomPaint(
                painter: _DialPainter(
                  fraction:
                      widget.progress ??
                      (widget.index + 1) / widget.steps.length,
                  steps: running ? 0 : widget.steps.length,
                  accent: Color(tone.accent),
                  dark: tone.dark,
                ),
                child: Center(
                  child: Text(
                    widget.label(widget.steps[widget.index]),
                    style: TextStyle(
                      color: fg,
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
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

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.fraction,
    required this.steps,
    required this.accent,
    required this.dark,
  });
  final double fraction;
  final int steps; // detent dots (0 = none)
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 14;
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.08);
    canvas.drawCircle(c, r, track);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      track..color = accent,
    );
    for (int i = 0; i < steps; i++) {
      final double a = -math.pi / 2 + 2 * math.pi * i / steps;
      canvas.drawCircle(
        c + Offset(math.cos(a), math.sin(a)) * (r - 18),
        1.6,
        Paint()
          ..color = (dark ? Colors.white : Colors.black).withValues(
            alpha: 0.25,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction ||
      old.steps != steps ||
      old.accent != accent ||
      old.dark != dark;
}

/// A short glass toast shown at the top of the screen.
void showGlassToast(BuildContext context, String message, {IconData? icon}) {
  final OverlayState overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) =>
        _Toast(message: message, icon: icon, onDone: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({required this.message, required this.onDone, this.icon});
  final String message;
  final IconData? icon;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.medium,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
    Future<void>.delayed(const Duration(milliseconds: 2400), () async {
      if (!mounted) return;
      await _c.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final Color fg = tone.dark ? Colors.white : const Color(0xFF15171C);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + Space.xs,
      left: Space.gutter,
      right: Space.gutter,
      // A notice only: taps reach the controls under it (the top bar,
      // tabs) while it shows.
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _c,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.4),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: _c, curve: Motion.emphasized)),
            child: Semantics(
              liveRegion: true,
              child: Material(
                type: MaterialType.transparency,
                child: GlassSurface(
                  tier: GlassTier.chrome,
                  radius: Radii.capsule,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.l,
                    vertical: Space.s,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (widget.icon != null) ...<Widget>[
                        Icon(widget.icon, color: fg, size: 18),
                        const SizedBox(width: Space.xs),
                      ],
                      Flexible(
                        child: Text(
                          widget.message,
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
