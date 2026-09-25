import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:electrobright/design/components/mode_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Glyphs run their loop; under Reduce Motion each rests on its own
/// characteristic frame (not the start of its loop).
void main() {
  double timeOf(WidgetTester t) {
    final CustomPaint paint = t.widget<CustomPaint>(
      find.descendant(
        of: find.byType(ModeGlyph),
        matching: find.byType(CustomPaint),
      ),
    );
    return (paint.painter! as GlyphPainter).t.value;
  }

  Widget glyph(EbModeGlyph g, {required bool reduced}) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Center(
      child: SizedBox.square(
        dimension: 80,
        child: ModeGlyph(glyph: g, color: Colors.orange),
      ),
    ),
  );

  testWidgets('animated glyphs move on', (WidgetTester t) async {
    await t.pumpWidget(glyph(EbModeGlyph.breath, reduced: false));
    final double start = timeOf(t);
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 100));
    expect(timeOf(t), greaterThan(start));
  });

  testWidgets('under Reduce Motion each glyph rests on its own frame', (
    WidgetTester t,
  ) async {
    for (final EbModeGlyph g in EbModeGlyph.values) {
      await t.pumpWidget(glyph(g, reduced: true));
      await t.pump(const Duration(seconds: 1));
      expect(timeOf(t), ModeGlyph.stillTime(g), reason: '$g');
      expect(timeOf(t), isNot(0), reason: '$g');
    }
    // Blink rests lit, Breath near a full breath.
    expect((ModeGlyph.stillTime(EbModeGlyph.blink) * 1.6) % 1, lessThan(0.5));
    expect(ModeGlyph.stillTime(EbModeGlyph.breath), closeTo(1.78, 0.01));
  });

  testWidgets('turning Reduce Motion on stops on the still frame', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(glyph(EbModeGlyph.fireworks, reduced: false));
    await t.pump(const Duration(milliseconds: 700));
    await t.pumpWidget(glyph(EbModeGlyph.fireworks, reduced: true));
    await t.pump(const Duration(seconds: 1));
    expect(timeOf(t), ModeGlyph.stillTime(EbModeGlyph.fireworks));
  });
}
