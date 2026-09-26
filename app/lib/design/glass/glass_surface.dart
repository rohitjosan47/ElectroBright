import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/color/light_surfaces.dart';

import '../tokens/tokens.dart';
import '../tone/tone_scope.dart';

/// How much glass a surface gets (plan §11).
enum GlassTier {
  /// Real refraction (liquid_glass_widgets): floating chrome only — header
  /// and toolbar buttons, segmented thumbs. Up to seven on the control screen
  /// (measured on an iPhone: raster 2.4 ms average, 4.3 ms max).
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
    this.tint,
    this.elevated = true,
    this.liquid = false,
    this.quietGlint = false,
    super.key,
  });

  final Widget child;
  final GlassTier tier;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Tint with the light's colour (off for neutral chrome).
  final bool tinted;

  /// A stronger tint in this colour (e.g. a lit button in the light's
  /// accent), instead of the light's glass tint.
  final Color? tint;

  /// Panel tier: liquid glass optics for the choice tiles (effects, Solid
  /// Color, presets): a curved reflection across the top, a glint, a faint
  /// thicker-glass band inside the edge (refraction), a reflection along the
  /// bottom, a soft neutral glow and a contact shadow ([_LiquidSheen]).
  /// Painted under the content, so glyphs and text stay crisp.
  final bool liquid;

  /// Liquid tiles with small content near the top (preset slots): on the
  /// dark theme the glint is a long, thin, faint highlight instead of a
  /// bright dot, so the tile stays uncluttered.
  final bool quietGlint;

  /// Casts a drop shadow. Off for glass nested inside another surface (a
  /// segmented thumb, a slider in a panel): nothing it draws may leave its
  /// own bounds and spill over its container.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final GlassPolicy? policy = GlassPolicy.maybeOf(context);
    // Untinted glass depends on light/dark only, not on every step of a
    // tone glide (it is not rebuilt during colour drags).
    final bool dark = ToneScope.darkOf(context);
    final Color? strong = this.tint;
    final Color tint =
        strong ?? (tinted ? Color(ToneScope.of(context).tint) : Colors.white);

    if (policy?.solid ?? false) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: strong ?? (dark ? const Color(0xFF1C1E24) : Colors.white),
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
      if (!dark) return _lightChrome(tint, strong != null);
      return GlassContainer(
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        padding: padding,
        useOwnLayer: true,
        settings: LiquidGlassSettings(
          glassColor: tint.withValues(
            alpha: strong != null ? (dark ? 0.42 : 0.5) : (dark ? 0.14 : 0.22),
          ),
          thickness: 18,
          blur: 6,
        ),
        child: child,
      );
    }

    if (!dark) return _lightPanel(tint, strong);

    // Panel tier: translucent tint + specular rim + hairline, no backdrop.
    return DecoratedBox(
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: strong != null
              ? <Color>[
                  strong.withValues(alpha: dark ? 0.5 : 0.6),
                  strong.withValues(alpha: dark ? 0.35 : 0.45),
                ]
              : dark
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
            // Liquid tiles: a slightly dimmer rim on the dark theme.
            color: dark
                ? Color(liquid ? 0x22FFFFFF : 0x2EFFFFFF)
                : const Color(0x80FFFFFF),
            width: 0.8,
          ),
        ),
        shadows: <BoxShadow>[
          if (elevated)
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          if (elevated && liquid) ..._liquidShadows(dark: true),
        ],
      ),
      child: _withSheen(dark: true, Padding(padding: padding, child: child)),
    );
  }

  /// Liquid tiles: a tight contact shadow under the soft one (the light
  /// comes from above, as the reflections say) and a soft neutral glow.
  static List<BoxShadow> _liquidShadows({required bool dark}) => dark
      ? const <BoxShadow>[
          BoxShadow(
            color: Color(0x2E000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
          // Only a trace of glow: more would haze the dark canvas.
          BoxShadow(color: Color(0x05FFFFFF), blurRadius: 16),
        ]
      : const <BoxShadow>[
          // Light: highlights lead; the shadow stays soft and close.
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 16,
            offset: Offset(0, 5),
          ),
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
          BoxShadow(color: Color(0x8CFFFFFF), blurRadius: 16, spreadRadius: -2),
        ];

  Widget _withSheen(Widget content, {required bool dark}) => liquid
      ? CustomPaint(
          painter: _LiquidSheen(radius, dark: dark, quietGlint: quietGlint),
          child: content,
        )
      : content;

  ShapeBorder _shape({BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
        side: side,
      );

  static const List<BoxShadow> _chromeShadows = <BoxShadow>[
    BoxShadow(color: Color(0x1A000000), blurRadius: 18, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> _panelShadows = <BoxShadow>[
    BoxShadow(color: Color(0x14000000), blurRadius: 22, offset: Offset(0, 8)),
  ];

  static const BorderSide _hairline = BorderSide(
    color: Color(LightSurfaces.hairline),
    width: 0.8,
  );

  /// Light theme chrome: liquid glass as in iOS light appearance —
  /// translucent over the refracted canvas, a bright specular rim on top and
  /// a faint darker one below, and a soft, wide neutral shadow. A lit button
  /// is tinted in the light's colour (its caller adds the under-light).
  Widget _lightChrome(Color tint, bool lit) => DecoratedBox(
    decoration: ShapeDecoration(
      shape: _shape(),
      shadows: elevated ? _chromeShadows : null,
    ),
    child: CustomPaint(
      foregroundPainter: _GlassRim(radius),
      child: GlassContainer(
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        padding: padding,
        useOwnLayer: true,
        settings: LiquidGlassSettings(
          glassColor: tint.withValues(
            alpha: lit
                ? LightSurfaces.activeTintAlpha
                : LightSurfaces.chromeAlpha,
          ),
          thickness: 18,
          blur: 6,
          // The light appearance's veil: bright glass, not grey (less on a
          // lit button, so its colour shows).
          whitenStrength: lit ? 0.12 : 0.3,
        ),
        child: child,
      ),
    ),
  );

  /// Light theme panel: the same glass family in its cheaper form — light,
  /// translucent, the tint lifted towards white, the specular rim, a very
  /// light hairline and a soft, wide shadow.
  Widget _lightPanel(Color tint, Color? strong) {
    final int t = tint.toARGB32();
    return DecoratedBox(
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: strong != null
              ? <Color>[
                  strong.withValues(alpha: 0.62),
                  strong.withValues(alpha: 0.5),
                ]
              : <Color>[
                  Color(
                    LightSurfaces.panelColour(t, LightSurfaces.panelTopWhite),
                  ).withValues(alpha: LightSurfaces.panelTopAlpha),
                  Color(
                    LightSurfaces.panelColour(
                      t,
                      LightSurfaces.panelBottomWhite,
                    ),
                  ).withValues(alpha: LightSurfaces.panelBottomAlpha),
                ],
        ),
        shape: _shape(side: _hairline),
        shadows: elevated
            ? <BoxShadow>[
                // Liquid tiles: their own softer, closer shadow.
                if (!liquid) ..._panelShadows,
                if (liquid) ..._liquidShadows(dark: false),
              ]
            : null,
      ),
      child: CustomPaint(
        foregroundPainter: _GlassRim(radius),
        child: _withSheen(dark: false, Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// The light theme's glass edge: a bright specular rim along the top that
/// fades out by the middle, and a faint darker rim along the bottom.
class _GlassRim extends CustomPainter {
  const _GlassRim(this.radius);
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = (Offset.zero & size).deflate(0.6);
    final Path edge = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    ).getOuterPath(r);
    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xE6FFFFFF),
            Color(0x00FFFFFF),
            Color(0x00000000),
            Color(0x1A000000),
          ],
          stops: <double>[0, 0.45, 0.6, 1],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_GlassRim old) => old.radius != radius;
}

/// Liquid glass optics for a choice tile, painted between the glass and its
/// content. The light comes from above: a soft curved reflection across the
/// top (like a window reflected on a rounded liquid surface), a small glint
/// near the top-right, a faint band just inside the edge where the glass is
/// thickest and bends the light (neutral: it keeps the tile's own colour)
/// and a thin reflection along the bottom edge. No streaks.
class _LiquidSheen extends CustomPainter {
  const _LiquidSheen(
    this.radius, {
    required this.dark,
    this.quietGlint = false,
  });
  final double radius;
  final bool dark;
  final bool quietGlint;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final Rect rect = Offset.zero & size;
    final Path shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    ).getOuterPath(rect);
    canvas.save();
    canvas.clipPath(shape);
    // Light: a little more luminance (keeps the tiles light and airy); dark:
    // a little less brightness (keeps the white text crisp). Both neutral.
    canvas.drawRect(
      rect,
      Paint()
        ..color = dark
            ? Colors.black.withValues(alpha: 0.32)
            : Colors.white.withValues(alpha: 0.2),
    );
    // The reflection: a large soft oval whose lower edge curves across the
    // top; blurred, so it fades out evenly all round (no hard line).
    final double soft = math.min(w, h) * 0.12;
    canvas.drawOval(
      Rect.fromLTWH(-w * 0.1, -h * 0.66, w * 1.2, h),
      Paint()
        ..color = Colors.white.withValues(alpha: dark ? 0.055 : 0.46)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, soft),
    );
    // Refraction at the thick edge: a faint band just inside it. Light:
    // only towards the lower edge, away from the light (never an even ring);
    // dark: a trace of white.
    final RRect edge = RRect.fromRectAndRadius(
      rect.deflate(3),
      Radius.circular(radius - 3),
    );
    canvas.drawRRect(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? <Color>[
                  Colors.white.withValues(alpha: 0.014),
                  Colors.white.withValues(alpha: 0.01),
                ]
              : <Color>[
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: 0.025),
                ],
          stops: dark ? null : const <double>[0, 0.55, 1],
        ).createShader(rect),
    );
    // A thin reflection along the bottom edge.
    final RRect inner = RRect.fromRectAndRadius(
      rect.deflate(1.2),
      Radius.circular(radius - 1.2),
    );
    canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: dark ? 0.12 : 0.6),
          ],
          stops: const <double>[0, 0.82, 1],
        ).createShader(rect),
    );
    // The glint: the light source reflected near the top-right. Quiet
    // (dark preset slots): long, thin and faint, across the top.
    final double g = math.min(w, h);
    final bool quiet = dark && quietGlint;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          quiet ? w * 0.56 : w - g * 0.3,
          h * (quiet ? 0.07 : 0.085),
        ),
        width: quiet ? w * 0.52 : g * 0.2,
        height: g * (quiet ? 0.026 : 0.04),
      ),
      Paint()
        ..color = Colors.white.withValues(
          alpha: quiet ? 0.08 : (dark ? 0.16 : 0.8),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, quiet ? 1.8 : 1.2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LiquidSheen old) =>
      old.radius != radius || old.dark != dark || old.quietGlint != quietGlint;
}
