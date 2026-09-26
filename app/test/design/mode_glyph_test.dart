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

  // Frames between steps would be identical: the glyph asks for none.
  testWidgets('steps at 30 fps with no frames between steps', (
    WidgetTester t,
  ) async {
    const int vsync = 8333; // µs, a 120 Hz display
    await t.pumpWidget(glyph(EbModeGlyph.breath, reduced: false));
    // Reference: a per-vsync ticker accumulating frame time, stepping once
    // 1/30 s has built up.
    double expected = timeOf(t);
    int acc = 0;
    for (int k = 1; k <= 120; k++) {
      await t.pump(const Duration(microseconds: vsync));
      acc += vsync;
      if (acc >= 33333) {
        expected += acc / 1e6;
        acc = 0;
      }
      expect(timeOf(t), closeTo(expected, 1e-9), reason: 'frame $k');
      // Between steps it sleeps on a timer: no frame is pending (a step's
      // frame is asked for when its timer fires).
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'frame $k');
      expect(t.binding.transientCallbackCount, 0, reason: 'frame $k');
    }
  });

  testWidgets('Solid never asks for a frame', (WidgetTester t) async {
    await t.pumpWidget(glyph(EbModeGlyph.solid, reduced: false));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.binding.hasScheduledFrame, isFalse);
    expect(t.binding.transientCallbackCount, 0);
  });

  testWidgets('a muted glyph asks for no frames and resumes unmuted', (
    WidgetTester t,
  ) async {
    Widget muted(bool enabled) => TickerMode(
      enabled: enabled,
      child: glyph(EbModeGlyph.fire, reduced: false),
    );
    await t.pumpWidget(muted(true));
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(muted(false));
    final double at = timeOf(t);
    for (int i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16));
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'frame $i');
    }
    expect(timeOf(t), at);
    await t.pumpWidget(muted(true));
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 40));
    expect(timeOf(t), greaterThan(at));
  });
}
