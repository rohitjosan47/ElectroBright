import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../core/color/color_science.dart';
import '../tokens/tokens.dart';
import 'screen_colour.dart';

/// [builder] with [colour], gliding to each new colour in OKLCH on a short
/// [Motion.smooth] spring, so a single step never flashes; a stream of
/// changes retargets the glide instead of restarting it. At once under
/// Reduce Motion, and while [follow] (a finger is on the colour: the display
/// follows it exactly).
class ColourGlide extends StatefulWidget {
  const ColourGlide({
    required this.colour,
    required this.builder,
    this.follow = false,
    this.child,
    super.key,
  });

  final Color colour;

  /// Show [colour] as it is, without gliding (and end a glide under way).
  final bool follow;
  final Widget Function(BuildContext context, Color colour, Widget? child)
  builder;
  final Widget? child;

  @override
  State<ColourGlide> createState() => _ColourGlideState();
}

class _ColourGlideState extends State<ColourGlide>
    with SingleTickerProviderStateMixin {
  /// Progress from [_from] to [_to]; 1 = arrived.
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late Color _from = widget.colour;
  late Color _to = widget.colour;

  @override
  void didUpdateWidget(ColourGlide old) {
    super.didUpdateWidget(old);
    if (widget.follow && _c.isAnimating) {
      _snap();
      return;
    }
    if (widget.colour == _to) return;
    if (widget.follow || Motion.reduced(context)) {
      _snap();
      return;
    }
    // Glide on from where the colour is now, keeping its speed (as
    // ToneScope does for the palette).
    final double x = _c.value.clamp(0.0, 1.0);
    final double speed = _c.isAnimating ? _c.velocity : 0;
    final double carried = x < 1 ? (speed / (1 - x)).clamp(0.0, 8.0) : 0.0;
    _from = _current;
    _to = widget.colour;
    _c.value = 0;
    unawaited(
      _c
          .animateWith(SpringSimulation(Motion.smooth, 0, 1, carried))
          // Land exactly on the colour (the spring stops within tolerance).
          .then((_) => _c.value = 1),
    );
  }

  void _snap() {
    _c.stop();
    _c.value = 1;
    _from = _to = widget.colour;
  }

  Color get _current {
    final double x = _c.value.clamp(0.0, 1.0);
    if (x >= 1) return _to;
    // Unrounded all the way, so the glide never steps back by a rounding.
    return screenColour(
      ColorScience.fromOklch(
        ColorScience.toGamut(
          ColorScience.lerp(
            ColorScience.toOklch(linearOf(_from)),
            ColorScience.toOklch(linearOf(_to)),
            x,
          ),
        ),
      ).clamp01(),
    ).withValues(alpha: _from.a + (_to.a - _from.a) * x);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (BuildContext context, Widget? child) =>
        widget.builder(context, _current, child),
    child: widget.child,
  );
}
