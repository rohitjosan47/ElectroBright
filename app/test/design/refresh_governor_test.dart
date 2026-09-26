import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:electrobright/design/components/mode_glyph.dart';
import 'package:electrobright/design/platform/refresh_governor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The display's high refresh rate is asked for only while something moves
/// at the display rate or a finger is down, and let go when idle.
void main() {
  const Duration vsync = Duration(microseconds: 8333);

  Future<void> frames(WidgetTester t, Duration d) async {
    for (int i = 0; i < d.inMicroseconds ~/ vsync.inMicroseconds; i++) {
      await t.pump(vsync);
    }
  }

  late List<bool> sent;
  late RefreshGovernor g;
  setUp(() {
    sent = <bool>[];
    g = RefreshGovernor(sent.add);
  });
  tearDown(() => g.stop());

  testWidgets('idle: the system chooses', (WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    g.start();
    await frames(t, const Duration(seconds: 1));
    expect(g.high, isFalse);
    expect(sent, isEmpty);
  });

  testWidgets('a finger down asks for it until shortly after it lifts', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(const SizedBox.expand());
    g.start();
    final TestGesture f = await t.startGesture(const Offset(50, 50));
    expect(g.high, isTrue);
    await t.pump(const Duration(seconds: 2));
    expect(g.high, isTrue, reason: 'held still, still down');
    await f.up();
    await t.pump(const Duration(milliseconds: 300));
    expect(g.high, isTrue);
    await t.pump(const Duration(milliseconds: 200));
    expect(g.high, isFalse);
    expect(sent, <bool>[true, false]);
  });

  testWidgets('an animation asks for it; idle again, it is let go', (
    WidgetTester t,
  ) async {
    final AnimationController c = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 600),
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      AnimatedBuilder(
        animation: c,
        builder: (_, _) => Opacity(opacity: c.value, child: const SizedBox()),
      ),
    );
    g.start();
    await frames(t, const Duration(milliseconds: 200));
    expect(g.high, isFalse);
    c.forward();
    await frames(t, const Duration(milliseconds: 100));
    expect(g.high, isTrue);
    await frames(t, const Duration(milliseconds: 600));
    expect(c.isCompleted, isTrue);
    await t.pump(const Duration(milliseconds: 500));
    expect(g.high, isFalse);
    g.stop();
  });

  testWidgets('glyphs stepping at 30 Hz never ask for it, even two sets '
      'out of phase', (WidgetTester t) async {
    Widget glyphs({required bool second}) => Row(
      textDirection: TextDirection.ltr,
      children: <Widget>[
        const SizedBox.square(
          dimension: 40,
          child: ModeGlyph(glyph: EbModeGlyph.fire, color: Colors.orange),
        ),
        if (second)
          const SizedBox.square(
            dimension: 40,
            child: ModeGlyph(glyph: EbModeGlyph.breath, color: Colors.blue),
          ),
      ],
    );
    await t.pumpWidget(glyphs(second: false));
    g.start();
    await frames(t, const Duration(milliseconds: 20));
    await t.pumpWidget(glyphs(second: true));
    await frames(t, const Duration(seconds: 2));
    expect(g.high, isFalse);
    expect(sent, isEmpty);
  });
}
