import 'package:flutter/material.dart';

import '../../core/color/light_tone.dart';
import '../tokens/tokens.dart';

/// Provides the current [LightTone] (the palette derived from the light's
/// colour), animated in OKLab whenever it changes.
class ToneScope extends StatefulWidget {
  const ToneScope({required this.tone, required this.child, super.key});

  final LightTone tone;
  final Widget child;

  static LightTone of(BuildContext context) {
    final _ToneInherited? s = context
        .dependOnInheritedWidgetOfExactType<_ToneInherited>();
    if (s != null) return s.tone;
    return LightTone.neutral(
      dark: Theme.of(context).brightness == Brightness.dark,
    );
  }

  @override
  State<ToneScope> createState() => _ToneScopeState();
}

class _ToneScopeState extends State<ToneScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.tone,
  );
  late LightTone _from = widget.tone;
  late LightTone _to = widget.tone;

  @override
  void didUpdateWidget(ToneScope old) {
    super.didUpdateWidget(old);
    if (widget.tone == _to) return;
    _from = _current;
    _to = widget.tone;
    if (Motion.reduced(context) || _from.dark != _to.dark) {
      _from = _to;
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  LightTone get _current => _c.isAnimating
      ? LightTone.lerp(_from, _to, Motion.emphasized.transform(_c.value))
      : _to;

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

class _ToneInherited extends InheritedWidget {
  const _ToneInherited({required this.tone, required super.child});
  final LightTone tone;

  @override
  bool updateShouldNotify(_ToneInherited old) => old.tone != tone;
}
