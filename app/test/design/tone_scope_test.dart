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

  testWidgets('a stream of changes glides on and settles on the latest', (
    WidgetTester t,
  ) async {
    final LightTone red = tone(1, 0, 0);
    final LightTone green = tone(0, 1, 0);
    final LightTone blue = tone(0, 0, 1);
    await t.pumpWidget(scope(red));
    await t.pumpWidget(scope(green));
    // A new tone every frame (a colour drag): retargeted, never snapped.
    for (int i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 16));
      await t.pumpWidget(scope(i.isEven ? blue : green));
      expect(seen, isNot(anyOf(blue, green)));
    }
    await t.pumpWidget(scope(blue));
    await t.pump(const Duration(milliseconds: 16));
    expect(seen, isNot(blue));
    await t.pumpAndSettle();
    expect(seen, blue);
  });

  testWidgets('one change glides instead of jumping', (WidgetTester t) async {
    final LightTone red = tone(1, 0, 0);
    final LightTone blue = tone(0, 0, 1);
    await t.pumpWidget(scope(red));
    await t.pumpWidget(scope(blue));
    await t.pump(const Duration(milliseconds: 50));
    expect(seen, isNot(anyOf(red, blue)));
    await t.pump(Motion.tone * 2);
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

  testWidgets('light/dark-only readers are not rebuilt while the tone glides', (
    WidgetTester t,
  ) async {
    int darkBuilds = 0;
    int fullBuilds = 0;
    Widget scoped(LightTone l) => ToneScope(
      tone: l,
      child: Column(
        children: <Widget>[
          Builder(
            builder: (BuildContext context) {
              ToneScope.darkOf(context);
              darkBuilds++;
              return const SizedBox();
            },
          ),
          Builder(
            builder: (BuildContext context) {
              ToneScope.of(context);
              fullBuilds++;
              return const SizedBox();
            },
          ),
        ],
      ),
    );
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: scoped(tone(1, 0, 0)),
      ),
    );
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: scoped(tone(0, 0, 1)),
      ),
    );
    // From here only the glide runs: the full reader follows every step,
    // the light/dark reader is left alone.
    final int dark0 = darkBuilds;
    final int full0 = fullBuilds;
    await t.pumpAndSettle();
    expect(darkBuilds, dark0);
    expect(fullBuilds - full0, greaterThan(3));
  });
}
