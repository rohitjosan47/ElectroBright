import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/components/mode_glyph.dart';
import 'package:electrobright/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The orb crossfades when the effect's glyph changes, never for a colour.
void main() {
  final EbModeSpec solid = EbModeCatalog.byId(EbModeCatalog.solid);
  final EbModeSpec other = EbModeCatalog.modes.firstWhere(
    (EbModeSpec m) => m.glyph != solid.glyph,
  );

  Widget orb(EbModeSpec spec, Color color, {bool reduced = false}) =>
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Localizations(
          locale: const Locale('en'),
          delegates: AppLocalizations.localizationsDelegates,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: LightOrb(spec: spec, color: color, on: true),
            ),
          ),
        ),
      );

  testWidgets('a colour change keeps the same glyph, no crossfade', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(orb(solid, Colors.red));
    final State before = t.state(find.byType(ModeGlyph));
    await t.pumpWidget(orb(solid, Colors.blue));
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byType(ModeGlyph), findsOneWidget);
    // Same element and state: updated in place, not rebuilt from scratch.
    expect(t.state(find.byType(ModeGlyph)), same(before));
    expect(t.widget<ModeGlyph>(find.byType(ModeGlyph)).color, Colors.blue);
  });

  testWidgets('a new glyph crossfades in, then the old one is gone', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(orb(solid, Colors.red));
    final State outgoing = t.state(find.byType(ModeGlyph));
    await t.pumpWidget(orb(other, Colors.red));
    await t.pump(const Duration(milliseconds: 100));
    // Both during the fade; the outgoing keeps its state.
    expect(find.byType(ModeGlyph), findsNWidgets(2));
    expect(t.stateList(find.byType(ModeGlyph)).contains(outgoing), isTrue);
    // The incoming one grows into place.
    final ScaleTransition grow = t
        .widgetList<ScaleTransition>(
          find.ancestor(
            of: find.byWidgetPredicate(
              (Widget w) => w is ModeGlyph && w.glyph == other.glyph,
            ),
            matching: find.byType(ScaleTransition),
          ),
        )
        .first;
    expect(grow.scale.value, inInclusiveRange(0.92, 1.0));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byType(ModeGlyph), findsOneWidget);
    expect(t.widget<ModeGlyph>(find.byType(ModeGlyph)).glyph, other.glyph);
  });

  testWidgets('under Reduce Motion the glyph is swapped at once', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(orb(solid, Colors.red, reduced: true));
    await t.pumpWidget(orb(other, Colors.red, reduced: true));
    expect(find.byType(ModeGlyph), findsOneWidget);
    expect(t.widget<ModeGlyph>(find.byType(ModeGlyph)).glyph, other.glyph);
  });
}
