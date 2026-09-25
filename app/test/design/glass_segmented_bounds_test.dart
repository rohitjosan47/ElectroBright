import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The segmented thumb stays inside its track on every frame of a switch:
/// inset by the track's padding, concentric with it, squashed against an
/// end by the spring's overshoot, never past it.
void main() {
  const List<(int, String)> tabs = <(int, String)>[
    (0, 'Colour'),
    (1, 'Effects'),
    (2, 'Presets'),
  ];
  const double inset = GlassSegmented.inset;

  Widget harness({required bool dark}) {
    int selected = 0;
    return MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 353,
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter set) =>
                  GlassSegmented<int>(
                    segments: tabs,
                    selected: selected,
                    onChanged: (int v) => set(() => selected = v),
                  ),
            ),
          ),
        ),
      ),
    );
  }

  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    testWidgets('$theme: the thumb stays inside its track, first <-> last', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(harness(dark: dark));
      final Finder seg = find.byType(GlassSegmented<int>);
      final Finder surfaces = find.descendant(
        of: seg,
        matching: find.byType(GlassSurface),
      );
      final Rect track = t.getRect(surfaces.first);
      final Rect inner = track.deflate(inset);
      final double segment = inner.width / tabs.length;
      Rect thumb() => t.getRect(surfaces.at(1));

      // Concentric: the thumb is the track's height less the padding, and
      // its radius the track's less the padding.
      expect(track.height, GlassSegmented.height);
      expect(thumb().height, inner.height);
      expect(GlassSegmented.thumbRadius, GlassSegmented.trackRadius - inset);
      expect(t.widget<GlassSurface>(surfaces.first).radius, track.height / 2);
      expect(t.widget<GlassSurface>(surfaces.at(1)).radius, inner.height / 2);
      // The thumb casts nothing outside itself.
      expect(t.widget<GlassSurface>(surfaces.at(1)).elevated, isFalse);

      for (final (String to, double end) in <(String, double)>[
        ('Presets', inner.right),
        ('Colour', inner.left),
      ]) {
        await t.tap(find.text(to));
        await t.pump();
        int frames = 0;
        bool squashed = false;
        final Rect from = thumb();
        while (t.binding.hasScheduledFrame && frames < 240) {
          await t.pump(const Duration(milliseconds: 16));
          frames++;
          final Rect r = thumb();
          final String at = '$theme, to $to, frame $frames: $r in $inner';
          expect(r.left, greaterThanOrEqualTo(inner.left - 1e-6), reason: at);
          expect(r.right, lessThanOrEqualTo(inner.right + 1e-6), reason: at);
          expect(r.top, greaterThanOrEqualTo(inner.top - 1e-6), reason: at);
          expect(r.bottom, lessThanOrEqualTo(inner.bottom + 1e-6), reason: at);
          // Squashed against the end it arrives at (the spring overshoots).
          final bool atEnd = to == 'Presets'
              ? (r.right - end).abs() < 1e-6
              : (r.left - end).abs() < 1e-6;
          if (atEnd && r.width < segment - 1) squashed = true;
        }
        expect(frames, greaterThan(10), reason: 'it animates');
        expect(thumb(), isNot(from));
        expect(squashed, isTrue, reason: 'the overshoot squashes, $theme');
        // At rest it fills its segment exactly, flush with the inner edge.
        expect(thumb().width, closeTo(segment, 0.01));
        expect(
          to == 'Presets' ? thumb().right : thumb().left,
          closeTo(end, 0.01),
        );
      }
    });
  }

  test('thumbSpan never leaves the inner bounds', () {
    const double inner = 347;
    for (final double x in <double>[-1, -0.3, 0, 0.5, 1, 1.7, 2, 2.3, 3]) {
      for (final double v in <double>[-40, -5, 0, 5, 40]) {
        final ({double left, double right}) s = GlassSegmented.thumbSpan(
          x: x,
          velocity: v,
          n: 3,
          inner: inner,
        );
        final String at = 'x $x, v $v: $s';
        expect(s.left, greaterThanOrEqualTo(0), reason: at);
        expect(s.right, lessThanOrEqualTo(inner), reason: at);
        // Squashed at most to a capsule no narrower than it is tall.
        expect(
          s.right - s.left,
          greaterThanOrEqualTo(GlassSegmented.height),
          reason: at,
        );
      }
    }
  });
}
