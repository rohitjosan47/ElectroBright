import 'package:flutter/widgets.dart';

import 'haptics.dart';

/// Makes the app's [Haptics] available to controls.
class HapticsScope extends InheritedWidget {
  const HapticsScope({required this.haptics, required super.child, super.key});
  final Haptics haptics;

  static final Haptics _fallback = Haptics();

  static Haptics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HapticsScope>()?.haptics ??
      _fallback;

  @override
  bool updateShouldNotify(HapticsScope old) => old.haptics != haptics;
}
