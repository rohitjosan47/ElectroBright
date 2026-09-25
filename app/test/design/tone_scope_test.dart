import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/design/tokens/tokens.dart';
import 'package:electrobright/design/tone/tone_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The palette glides to a new light colour; a stream of changes (a colour
/// drag) retargets the glide instead of restarting it every frame.
void main() {
  LightTone tone(double r, double g, double b) =>
      LightTone.derive(DisplayColor(LinearRgb(r, g, b), 1), dark: false);

  late LightTone seen;
  Widget scope(LightTone t) => ToneScope(
    tone: t,
    child: Builder(
      builder: (BuildContext context) {
        seen = ToneScope.of(context);
        return const SizedBox();
      },
    ),
  );

  testWidgets('changes mid-glide land on time, on the latest tone', (
    WidgetTester t,
  ) async {
    final LightTone red = tone(1, 0, 0);
    final LightTone green = tone(0, 1, 0);
    final LightTone blue = tone(0, 0, 1);
    await t.pumpWidget(scope(red));
    await t.pumpWidget(scope(green));
    // A new tone every frame for a while.
    for (int i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 16));
      await t.pumpWidget(scope(i.isEven ? blue : green));
    }
    await t.pumpWidget(scope(blue));
    // One glide from the first change: done after Motion.tone, not later.
    await t.pump(Motion.tone - const Duration(milliseconds: 160));
    await t.pump(const Duration(milliseconds: 1));
    expect(seen, blue);
  });

  testWidgets('under Reduce Motion the tone switches at once', (
    WidgetTester t,
  ) async {
    final LightTone red = tone(1, 0, 0);
    final LightTone blue = tone(0, 0, 1);
    Widget reduced(LightTone l) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: scope(l),
    );
    await t.pumpWidget(reduced(red));
    await t.pumpWidget(reduced(blue));
    await t.pump();
    expect(seen, blue);
  });
}
