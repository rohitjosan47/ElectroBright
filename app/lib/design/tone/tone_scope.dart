import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../core/color/light_tone.dart';
import '../tokens/tokens.dart';

/// Provides the current [LightTone] (the palette derived from the light's
/// colour), gliding in OKLab on a [Motion.smooth] spring whenever it changes.
class ToneScope extends StatefulWidget {
  const ToneScope({required this.tone, required this.child, super.key});

  final LightTone tone;
  final Widget child;

  /// The whole palette: rebuilt on every step of a glide.
  static LightTone of(BuildContext context) {
    final _ToneInherited? s = InheritedModel.inheritFrom<_ToneInherited>(
      context,
    );
    if (s != null) return s.tone;
    return LightTone.neutral(
      dark: Theme.of(context).brightness == Brightness.dark,
    );
  }

  /// Only whether the palette is dark: a widget that needs no more (untinted
  /// glass, its icons) is not rebuilt while the light's colour glides.
  static bool darkOf(BuildContext context) {
    final _ToneInherited? s = InheritedModel.inheritFrom<_ToneInherited>(
      context,
      aspect: _ToneAspect.dark,
    );
    return s?.tone.dark ?? Theme.of(context).brightness == Brightness.dark;
  }

  @override
  State<ToneScope> createState() => _ToneScopeState();
}

class _ToneScopeState extends State<ToneScope>
    with SingleTickerProviderStateMixin {
  /// Progress from [_from] to [_to]; 1 = arrived.
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late LightTone _from = widget.tone;
  late LightTone _to = widget.tone;

  @override
  void didUpdateWidget(ToneScope old) {
    super.didUpdateWidget(old);
    if (widget.tone == _to) return;
    if (Motion.reduced(context) || widget.tone.dark != _to.dark) {
      _c.stop();
      _c.value = 1;
      _from = _to = widget.tone;
      return;
    }
    // A new target mid-glide (a colour drag changes it every frame): glide
    // on from where the palette is now, keeping its speed, so a stream of
    // changes is followed smoothly instead of restarting each time.
    final double x = _c.value.clamp(0.0, 1.0);
    final double speed = _c.isAnimating ? _c.velocity : 0;
    final double carried = x < 1 ? (speed / (1 - x)).clamp(0.0, 8.0) : 0.0;
    _from = _current;
    _to = widget.tone;
    _c
      ..value = 0
      ..animateWith(SpringSimulation(Motion.smooth, 0, 1, carried));
  }

  LightTone get _current {
    final double x = _c.value.clamp(0.0, 1.0);
    return x >= 1 ? _to : LightTone.lerp(_from, _to, x);
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
        _ToneInherited(tone: _current, child: child!),
    child: widget.child,
  );
}

enum _ToneAspect { dark }

class _ToneInherited extends InheritedModel<_ToneAspect> {
  const _ToneInherited({required this.tone, required super.child});
  final LightTone tone;

  @override
  bool updateShouldNotify(_ToneInherited old) => old.tone != tone;

  @override
  bool updateShouldNotifyDependent(
    _ToneInherited old,
    Set<_ToneAspect> dependencies,
  ) => dependencies.contains(_ToneAspect.dark) && old.tone.dark != tone.dark;
}
