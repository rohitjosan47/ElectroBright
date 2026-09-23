import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/color/light_tone.dart';
import '../tokens/tokens.dart';
import '../tone/tone_scope.dart';

/// How much glass a surface gets (plan §11).
enum GlassTier {
  /// Real refraction (liquid_glass_widgets): floating chrome only, at most
  /// four on screen — header capsule, tab bar, segmented thumb, floating
  /// buttons.
  chrome,

  /// Cheap "fake glass" for content panels: translucent tint, specular rim,
  /// hairline. No backdrop sampling (the canvas behind is already soft), so
  /// it is free to scroll.
  panel,
}

/// Global glass policy: Reduce Transparency or the runtime off switch make
/// every surface solid; route transitions drop chrome to the panel tier.
class GlassPolicy extends InheritedWidget {
  const GlassPolicy({
    required super.child,
    this.solid = false,
    this.refraction = true,
    super.key,
  });

  /// Reduce Transparency / high contrast: opaque surfaces.
  final bool solid;

  /// Allow refraction (off on low-end devices or via the kill switch).
  final bool refraction;

  static GlassPolicy? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassPolicy>();

  @override
  bool updateShouldNotify(GlassPolicy old) =>
      old.solid != solid || old.refraction != refraction;
}

/// The one way the app draws glass. Swappable backend: liquid_glass_widgets
/// for chrome, an in-house painter for panels, solid under Reduce
/// Transparency.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    required this.child,
    this.tier = GlassTier.panel,
    this.radius = Radii.large,
    this.padding = EdgeInsets.zero,
    this.tinted = true,
    super.key,
  });

  final Widget child;
  final GlassTier tier;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Tint with the light's colour (off for neutral chrome).
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final LightTone tone = ToneScope.of(context);
    final GlassPolicy? policy = GlassPolicy.maybeOf(context);
    final bool dark = tone.dark;
    final Color tint = tinted
        ? Color(tone.tint)
        : (dark ? Colors.white : Colors.white);

    if (policy?.solid ?? false) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: dark ? const Color(0xFF1C1E24) : Colors.white,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(
              color: dark ? const Color(0x33FFFFFF) : const Color(0x22000000),
            ),
          ),
        ),
        child: Padding(padding: padding, child: child),
      );
    }

    if (tier == GlassTier.chrome && (policy?.refraction ?? true)) {
      return GlassContainer(
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        padding: padding,
        useOwnLayer: true,
        settings: LiquidGlassSettings(
          glassColor: tint.withValues(alpha: dark ? 0.14 : 0.22),
          thickness: 18,
          blur: 6,
        ),
        child: child,
      );
    }

    // Panel tier: translucent tint + specular rim + hairline, no backdrop.
    return DecoratedBox(
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? <Color>[
                  Color.lerp(tint, Colors.white, 0.10)!.withValues(alpha: 0.16),
                  tint.withValues(alpha: 0.08),
                ]
              : <Color>[
                  Colors.white.withValues(alpha: 0.72),
                  Color.lerp(tint, Colors.white, 0.6)!.withValues(alpha: 0.46),
                ],
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: dark ? const Color(0x2EFFFFFF) : const Color(0x80FFFFFF),
            width: 0.8,
          ),
        ),
        shadows: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
