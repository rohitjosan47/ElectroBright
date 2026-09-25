import 'package:flutter/widgets.dart';

/// How bright the light shows right now, 0..1 (0 when sleeping), gliding
/// between values. Painters take it as their repaint listenable, so the
/// canvas and the orb follow a brightness drag, a sleep or a wake without
/// rebuilding anything; text and control colours stay at full brightness.
class LightLevel extends InheritedWidget {
  const LightLevel({required this.level, required super.child, super.key});

  final Animation<double> level;

  /// The level, or null outside a light's screen.
  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LightLevel>()?.level;

  /// The level, full outside a light's screen.
  static Animation<double> of(BuildContext context) =>
      maybeOf(context) ?? kAlwaysCompleteAnimation;

  @override
  bool updateShouldNotify(LightLevel old) => old.level != level;
}
