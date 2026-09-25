import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

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
    final LightTone tone = ToneScope.of(context);
    final Haptics h = HapticsScope.of(context);
    final bool enabled = widget.onPressed != null;
    final Color fg = widget.active
        ? Color(tone.onAccent)
        : (tone.dark ? Colors.white : const Color(0xFF15171C));
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
              child: widget.active
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(tone.accent),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Color(tone.glow).withValues(alpha: 0.55),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                      child: Icon(
                        widget.icon,
                        color: fg,
                        size: widget.size * 0.48,
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
class GlassSegmented<T> extends StatefulWidget {
  const GlassSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

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
      _x.animateWith(
        SpringSimulation(Motion.liquid, _x.value, target, _x.velocity),
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
    final LightTone tone = ToneScope.of(context);
    final Haptics h = HapticsScope.of(context);
    final int n = widget.segments.length;
    final Color fg = tone.dark ? Colors.white : const Color(0xFF15171C);
    return SizedBox(
      height: 44,
      child: GlassSurface(
        radius: Radii.capsule,
        padding: const EdgeInsets.all(3),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double w = c.maxWidth / n;
            return Stack(
              children: <Widget>[
                AnimatedBuilder(
                  animation: _x,
                  builder: (BuildContext context, _) {
                    // Liquid stretch: the thumb widens with its speed.
                    final double stretch = (_x.velocity.abs() * 0.06).clamp(
                      0.0,
                      0.35,
                    );
                    return Positioned(
                      left: _x.value * w - stretch * w / 2,
                      width: w * (1 + stretch),
                      top: 0,
                      bottom: 0,
                      child: const GlassSurface(
                        tier: GlassTier.chrome,
                        radius: Radii.capsule,
                        tinted: false,
                        child: SizedBox.expand(),
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
                                    alpha: value == widget.selected ? 1 : 0.65,
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

/// A lighting-mode tile: animated glyph, name, lit when active.
class ModeTile extends StatelessWidget {
  const ModeTile({
    required this.spec,
    required this.selected,
    required this.onTap,
    required this.color,
    this.animate = true,
    super.key,
  });

  final EbModeSpec spec;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final Haptics h = HapticsScope.of(context);
    final List<Color> palette = <Color>[
      for (final int c in spec.gradient) Color(c),
    ];
    final bool own = spec.colorUse == EbColorUse.never;
    final Color fg = tone.dark ? Colors.white : const Color(0xFF15171C);
    return Semantics(
      button: true,
      selected: selected,
      label: spec.name,
      hint: spec.description,
      child: GestureDetector(
        onTap: () {
          h.play(HapticEvent.selection);
          onTap();
        },
        child: AnimatedContainer(
          duration: Motion.medium,
          curve: Motion.emphasized,
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(Radii.medium),
              side: BorderSide(
                color: selected ? Color(tone.accent) : Colors.transparent,
                width: 2,
              ),
            ),
            shadows: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: Color(tone.glow).withValues(alpha: 0.35),
                      blurRadius: 20,
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: GlassSurface(
            radius: Radii.medium,
            padding: const EdgeInsets.all(Space.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: ModeGlyph(
                    glyph: spec.glyph,
                    color: own ? palette.first : color,
                    palette: palette,
                    animate: animate,
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
      ),
    );
  }
}

/// The hero "light orb": what the light is doing right now.
class LightOrb extends StatelessWidget {
  const LightOrb({
    required this.spec,
    required this.color,
    required this.on,
    this.size = 180,
    this.speed = 1,
    super.key,
  });

  final EbModeSpec spec;
  final Color color;
  final bool on;
  final double size;
  final double speed;

  @override
  Widget build(BuildContext context) {
    final List<Color> palette = <Color>[
      for (final int c in spec.gradient) Color(c),
    ];
    return Semantics(
      image: true,
      label: on ? '${spec.name}, on' : 'Off',
      child: SizedBox.square(
        dimension: size,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0.18,
          duration: Motion.medium,
          child: ModeGlyph(
            glyph: spec.glyph,
            color: spec.colorUse == EbColorUse.never ? palette.first : color,
            palette: palette,
            animate: on,
            speed: speed,
          ),
        ),
      ),
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
    );
  }
}
