// The app's animations run on elapsed time, not on frames: on a 60 Hz and a
// 120 Hz display they are in the same place at the same time after they
// start. (When one starts depends on the frame that starts it; from there
// on only time counts.)
import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/components/mode_glyph.dart';
import 'package:electrobright/design/glass/glass_surface.dart';
import 'package:electrobright/design/tone/colour_glide.dart';
import 'package:electrobright/design/tone/light_level.dart';
import 'package:electrobright/design/tone/tone_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// 60 Hz; two 120 Hz frames make exactly one.
const Duration hz60 = Duration(microseconds: 16666);
const Duration hz120 = Duration(microseconds: 8333);

typedef Sample = (int micros, List<double> value);

/// Pumps [window] at [frame] intervals, reading [read] before the first
/// frame and after every frame.
Future<List<Sample>> record(
  WidgetTester t,
  Duration frame,
  Duration window,
  List<double> Function() read,
) async {
  final List<Sample> out = <Sample>[(0, read())];
  for (
    int at = frame.inMicroseconds;
    at <= window.inMicroseconds;
    at += frame.inMicroseconds
  ) {
    await t.pump(frame);
    out.add((at, read()));
  }
  return out;
}

bool _same(List<double> a, List<double> b, double tolerance) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > tolerance) return false;
  }
  return true;
}

/// The curve after its start: the value at each 60 Hz frame from the frame
/// that started it: the one before its first change, or, when [known], the
/// first frame (the one that applies the change).
List<List<double>> fromStart(
  List<Sample> s,
  Duration frame, {
  bool known = false,
}) {
  final int first = known
      ? 2
      : s.indexWhere((Sample x) => !_same(x.$2, s.first.$2, 1e-6));
  expect(first, greaterThan(0), reason: 'it moves');
  final int start = s[first].$1 - frame.inMicroseconds;
  return <List<double>>[
    for (final Sample x in s)
      if (x.$1 >= start && (x.$1 - start) % hz60.inMicroseconds == 0) x.$2,
  ];
}

/// [tolerance]: a spring ends at the first frame within its own tolerance
/// of rest, so near the end the two may differ by that much.
void expectSameCurve(
  List<Sample> at60,
  List<Sample> at120, {
  double tolerance = 1e-3,
  bool known = false,
}) {
  final List<List<double>> a = fromStart(at60, hz60, known: known);
  final List<List<double>> b = fromStart(at120, hz120, known: known);
  final int n = a.length < b.length ? a.length : b.length;
  expect(n, greaterThan(20));
  for (int i = 0; i < n; i++) {
    expect(
      _same(a[i], b[i], tolerance),
      isTrue,
      reason: 'at ${i * 16.666} ms: 60 Hz ${a[i]}, 120 Hz ${b[i]}',
    );
  }
}

List<double> rgba(Color c) => <double>[c.r, c.g, c.b, c.a];

void main() {
  testWidgets('glyph time', (WidgetTester t) async {
    Future<List<Sample>> run(Duration frame) async {
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        const Center(
          child: SizedBox.square(
            dimension: 80,
            child: ModeGlyph(glyph: EbModeGlyph.fire, color: Colors.orange),
          ),
        ),
      );
      double time() =>
          (t
                      .widget<CustomPaint>(
                        find.descendant(
                          of: find.byType(ModeGlyph),
                          matching: find.byType(CustomPaint),
                        ),
                      )
                      .painter!
                  as GlyphPainter)
              .t
              .value;
      return record(
        t,
        frame,
        const Duration(seconds: 10),
        () => <double>[time()],
      );
    }

    final List<Sample> a = await run(hz60);
    final List<Sample> b = await run(hz120);
    // It steps at 30 Hz on either display: at any moment the two are within
    // one step, and they never drift apart.
    final Map<int, double> at120 = <int, double>{
      for (final Sample s in b) s.$1: s.$2.single,
    };
    for (final Sample s in a) {
      final double other = at120[s.$1]!;
      expect(
        (s.$2.single - other).abs(),
        lessThanOrEqualTo(1 / 24 + 1e-6),
        reason: 'at ${s.$1} µs',
      );
    }
  });

  testWidgets('ColourGlide', (WidgetTester t) async {
    Future<List<Sample>> run(Duration frame) async {
      Color target = Colors.red;
      late StateSetter set;
      Color shown = target;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            set = s;
            return ColourGlide(
              colour: target,
              builder: (_, Color c, _) {
                shown = c;
                return const SizedBox();
              },
            );
          },
        ),
      );
      set(() => target = Colors.blue);
      return record(t, frame, const Duration(seconds: 1), () => rgba(shown));
    }

    expectSameCurve(await run(hz60), await run(hz120));
  });

  testWidgets('ToneScope', (WidgetTester t) async {
    Future<List<Sample>> run(Duration frame) async {
      LightTone tone = LightTone.neutral(dark: true);
      late StateSetter set;
      LightTone shown = tone;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            set = s;
            return ToneScope(
              tone: tone,
              child: Builder(
                builder: (BuildContext context) {
                  shown = ToneScope.of(context);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      );
      final LightTone to = LightTone.derive(
        const DisplayColor(LinearRgb(0.9, 0.2, 0.1), 1),
        dark: true,
      );
      set(() => tone = to);
      return record(
        t,
        frame,
        const Duration(seconds: 1),
        () => rgba(Color(shown.tint)),
      );
    }

    // Its palette is 8-bit: the first step can round to no change, so the
    // start is the frame that applies the new tone.
    expectSameCurve(await run(hz60), await run(hz120), known: true);
  });

  testWidgets('GlassSegmented thumb', (WidgetTester t) async {
    Future<List<Sample>> run(Duration frame) async {
      int selected = 0;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 353,
                child: StatefulBuilder(
                  builder: (BuildContext context, StateSetter set) =>
                      GlassSegmented<int>(
                        segments: const <(int, String)>[
                          (0, 'Colour'),
                          (1, 'Effects'),
                          (2, 'Presets'),
                        ],
                        selected: selected,
                        onChanged: (int v) => set(() => selected = v),
                      ),
                ),
              ),
            ),
          ),
        ),
      );
      final Finder thumb = find
          .descendant(
            of: find.byType(GlassSegmented<int>),
            matching: find.byType(GlassSurface),
          )
          .at(1);
      await t.tap(find.text('Presets'));
      return record(t, frame, const Duration(seconds: 1), () {
        final Rect r = t.getRect(thumb);
        return <double>[r.left, r.right];
      });
    }

    expectSameCurve(await run(hz60), await run(hz120));
  });

  testWidgets('ChoiceFrame selection', (WidgetTester t) async {
    Future<List<Sample>> run(Duration frame) async {
      bool selected = false;
      late StateSetter set;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          home: Center(
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter s) {
                set = s;
                return ChoiceFrame(
                  selected: selected,
                  child: const SizedBox.square(dimension: 60),
                );
              },
            ),
          ),
        ),
      );
      List<double> frameOf() {
        final Finder box = find
            .descendant(
              of: find.byType(ChoiceFrame),
              matching: find.byType(DecoratedBox),
            )
            .first;
        final ShapeDecoration d =
            t.widget<DecoratedBox>(box).decoration as ShapeDecoration;
        final ShapeBorder shape = d.shape;
        return <double>[
          ...rgba(d.color ?? Colors.transparent),
          if (shape is OutlinedBorder) ...rgba(shape.side.color),
          for (final BoxShadow s
              in d.shadows ?? const <BoxShadow>[]) ...<double>[
            ...rgba(s.color),
            s.blurRadius,
            s.spreadRadius,
          ],
        ];
      }

      set(() => selected = true);
      return record(t, frame, const Duration(seconds: 1), frameOf);
    }

    expectSameCurve(await run(hz60), await run(hz120));
  });

  // The control screen's own glides: the light level and the tab switch.
  testWidgets('light level and tab switch', (WidgetTester t) async {
    Future<(List<Sample>, List<Sample>)> run(Duration frame) async {
      final DemoApp d = await DemoApp.start(t);
      await DemoApp.settle(t, 2);
      await d.open(t, 'Living room');
      await DemoApp.settle(t, 1);
      double level() => LightLevel.of(t.element(find.byType(LightOrb))).value;
      d.session('Living room').setBrightness(40);
      final List<Sample> glide = await record(
        t,
        frame,
        const Duration(seconds: 1),
        () => <double>[level()],
      );
      await DemoApp.settle(t, 1);
      final Finder switcher = find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString() == 'TabSwitcher',
      );
      await t.tap(find.text('Effects').first);
      final List<Sample> tabs = await record(
        t,
        frame,
        const Duration(milliseconds: 700),
        () => <double>[
          for (final Opacity o in t.widgetList<Opacity>(
            find.descendant(of: switcher, matching: find.byType(Opacity)),
          ))
            o.opacity,
        ].take(2).toList(),
      );
      await DemoApp.settle(t, 1);
      await DemoApp.shutDown(t);
      return (glide, tabs);
    }

    final (List<Sample>, List<Sample>) a = await run(hz60);
    final (List<Sample>, List<Sample>) b = await run(hz120);
    expectSameCurve(a.$1, b.$1);
    expectSameCurve(a.$2, b.$2);
  });
}
