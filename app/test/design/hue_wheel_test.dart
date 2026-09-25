import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wheel inside a scroll view: a touch on the square or the ring is the
/// wheel's at once; anywhere else the page scrolls.
void main() {
  late ScrollController scroll;
  late List<Hsv> changes;

  Future<void> pumpWheel(WidgetTester t) async {
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    changes = <Hsv>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: <Widget>[
              HueWheel(value: const Hsv(200, 0.5, 0.5), onChanged: changes.add),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
  }

  Rect wheel(WidgetTester t) => t.getRect(find.byType(CustomPaint).last);

  testWidgets('a vertical drag in the square changes the colour, not scroll', (
    WidgetTester t,
  ) async {
    await pumpWheel(t);
    final Rect box = wheel(t);
    // Square centre, dragged down: brightness falls.
    final TestGesture g = await t.startGesture(box.center);
    for (int i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, 8));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(changes.length, greaterThan(2));
    for (int i = 1; i < changes.length; i++) {
      expect(changes[i].v, lessThan(changes[i - 1].v));
    }
    expect(changes.last.h, 200); // the square keeps the hue
  });

  testWidgets('the thumb follows from the first pixel (no touch slop)', (
    WidgetTester t,
  ) async {
    await pumpWheel(t);
    // Off the starting value (the square's centre is s 0.5, v 0.5).
    final TestGesture g = await t.startGesture(
      wheel(t).center + const Offset(20, 20),
    );
    // The touch itself sets the colour under the finger...
    expect(changes, hasLength(1));
    // ...and a move smaller than any drag slop already moves it.
    await g.moveBy(const Offset(0, 2));
    expect(changes, hasLength(2));
    await g.up();
    await t.pumpAndSettle();
  });

  testWidgets('a drag starting outside the ring and square scrolls the page', (
    WidgetTester t,
  ) async {
    await pumpWheel(t);
    final Rect box = wheel(t);
    // The wheel's bottom-right corner is empty (beyond the ring's reach).
    await t.dragFrom(
      box.bottomRight - const Offset(6, 6),
      const Offset(0, -200),
    );
    await t.pumpAndSettle();
    expect(scroll.offset, greaterThan(100));
    expect(changes, isEmpty);
  });

  testWidgets('a disabled wheel lets every touch scroll', (
    WidgetTester t,
  ) async {
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    final List<Hsv> got = <Hsv>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: <Widget>[
              HueWheel(
                value: const Hsv(200, 0.5, 0.5),
                enabled: false,
                onChanged: got.add,
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await t.dragFrom(wheel(t).center, const Offset(0, -200));
    await t.pumpAndSettle();
    expect(scroll.offset, greaterThan(100));
    expect(got, isEmpty);
  });
}
