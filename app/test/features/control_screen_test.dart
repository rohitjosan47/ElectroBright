import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/components/mode_glyph.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/design/tokens/tokens.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The control screen follows what each light can do: one demo light of
/// every fixture type, opened from Home, checked against the twin's state.
void main() {
  /// A tab of the control screen (not the type badge's words).
  Finder tab(String name) => find.descendant(
    of: find.byType(GlassSegmented<ControlTab>),
    matching: find.text(name),
  );

  /// A slider by its accessibility label.
  Finder slider(String label) => find.byWidgetPredicate(
    (Widget w) => w is GlassSlider && w.semanticLabel == label,
  );

  Future<void> settle(WidgetTester t, [int seconds = 2]) =>
      DemoApp.settle(t, seconds);

  /// The single-white output caption is showing (its row is always there).
  bool captionShown(WidgetTester t) =>
      t
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('output-row')),
          )
          .opacity ==
      1;

  /// Drags the slider labelled [label] (the [nth] of them) to its warm or
  /// cool end.
  Future<void> slideToEnd(
    WidgetTester t,
    String label, {
    required bool warm,
    int nth = 0,
  }) async {
    await t.drag(slider(label).at(nth), Offset(warm ? -2000 : 2000, 0));
    await settle(t);
  }

  /// What the brightness pill says to accessibility ("70 %").
  String? pillValue(WidgetTester t) =>
      t.getSemantics(find.byKey(const ValueKey<String>('brightness'))).value;

  Future<DemoApp> open(WidgetTester t, String name) async {
    t.view.physicalSize = const Size(1179, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final DemoApp demo = await DemoApp.start(t);
    await demo.open(t, name);
    return demo;
  }

  testWidgets('single white: intensity only, 12 effects, full range', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Hallway');
    // No colour or white tab: the pill is the light's intensity.
    expect(tab('Colour'), findsNothing);
    expect(tab('White'), findsNothing);
    expect(slider('Intensity'), findsOneWidget);
    expect(find.byType(HueWheel), findsNothing);
    // Effects: every mode except Rainbow, and why.
    expect(find.byKey(const ValueKey<String>('mode-10')), findsNothing);
    for (final int m in <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13]) {
      expect(find.byKey(ValueKey<String>('mode-$m')), findsOneWidget);
    }
    expect(
      find.text("Rainbow isn't available on single-white lights."),
      findsOneWidget,
    );
    // Channel at half: the caption shows the real output; nothing rewrites
    // the channel until the user asks. Its row is always laid out, so
    // nothing under the pill jumps when it appears.
    expect(captionShown(t), isFalse);
    final Finder tabs = find.byType(GlassSegmented<ControlTab>);
    final Rect below = t.getRect(tabs);
    d
        .session('Hallway')
        .setColor(ChannelColor(ChannelLayout.w, const <int>[128]));
    await settle(t);
    expect(captionShown(t), isTrue);
    expect(t.getRect(tabs), below);
    expect(find.text('Output 50 %'), findsOneWidget);
    expect(d.twin('Hallway').color[0], 128);
    await t.tap(find.text('Use full range'));
    await settle(t);
    expect(d.twin('Hallway').color[0], 255);
    expect(d.twin('Hallway').brightness, 128);
    expect(captionShown(t), isFalse);
    await DemoApp.shutDown(t);
  });

  testWidgets('tunable white: temperature and level', (WidgetTester t) async {
    final DemoApp d = await open(t, 'Kitchen');
    expect(tab('White'), findsOneWidget);
    expect(tab('Colour'), findsNothing);
    expect(find.byType(HueWheel), findsNothing);
    expect(slider('Colour temperature'), findsOneWidget);
    expect(slider('Level'), findsOneWidget);
    // The temperature spans the LEDs' own range: warm end, warm LED only.
    await slideToEnd(t, 'Colour temperature', warm: true);
    expect(d.twin('Kitchen').color.values, <int>[0, 255]); // CW, WW
    await slideToEnd(t, 'Colour temperature', warm: false);
    expect(d.twin('Kitchen').color.values, <int>[255, 0]);
    // Effects in its own words.
    await t.tap(tab('Effects'));
    await settle(t, 1);
    expect(find.text('Temperature sweep'), findsOneWidget);
    expect(find.text('Rainbow'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('RGB: the colour wheel and three channels, no white LED', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    expect(tab('Colour'), findsOneWidget);
    expect(find.byType(HueWheel), findsOneWidget);
    expect(slider('White LED'), findsNothing);
    await t.tap(find.text('Channels'));
    await settle(t, 1);
    for (final String c in <String>['Red', 'Green', 'Blue']) {
      expect(slider(c), findsOneWidget, reason: c);
    }
    expect(slider('White'), findsNothing);
    // White is made from RGB: the square's top-left corner.
    final Rect box = t.getRect(find.byType(HueWheel));
    final double size = box.width < 300 ? box.width : 300;
    final double half = (size / 2 - 8 - size * 0.095 - 10) / 1.41421356;
    await t.tapAt(box.center - Offset(half + 4, half + 4));
    await settle(t);
    final ChannelColor c = d.twin('Desk strip').color;
    expect(c.values.reduce((int a, int b) => a < b ? a : b), greaterThan(150));
    await t.tap(tab('Effects'));
    await settle(t, 1);
    expect(find.text('Rainbow'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('RGBW: the wheel plus the white LED', (WidgetTester t) async {
    await open(t, 'Living room');
    expect(find.byType(HueWheel), findsOneWidget);
    expect(slider('White LED'), findsOneWidget);
    await t.tap(find.text('Channels'));
    await settle(t, 1);
    for (final String c in <String>['Red', 'Green', 'Blue', 'White']) {
      expect(slider(c), findsOneWidget, reason: c);
    }
    await DemoApp.shutDown(t);
  });

  testWidgets('RGB + CCT: colour or tunable white, switched explicitly', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Bedroom');
    // The factory look (both whites) is a white: the White side is shown.
    expect(slider('Colour temperature'), findsOneWidget);
    expect(find.byType(HueWheel), findsNothing);
    await slideToEnd(t, 'Colour temperature', warm: true);
    expect(d.twin('Bedroom').color.values, <int>[0, 0, 0, 0, 255]);
    // Colour: the whites go to zero.
    await t.tap(
      find.descendant(
        of: find.byType(ColourEditor),
        matching: find.text('Colour'),
      ),
    );
    await settle(t);
    expect(find.byType(HueWheel), findsOneWidget);
    final ChannelColor c = d.twin('Bedroom').color;
    expect(c.values.sublist(3), <int>[0, 0]);
    expect(c.values.sublist(0, 3).any((int v) => v > 0), isTrue);
    await DemoApp.shutDown(t);
  });

  testWidgets('an unavailable light shows its last look with a note', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    expect(find.byKey(const ValueKey<String>('offline-note')), findsNothing);
    d.radio.setAvailable('demo-rgb', available: false);
    // Tearing the session down needs real async time (as at shutdown).
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settle(t);
    expect(find.byKey(const ValueKey<String>('offline-note')), findsOneWidget);
    expect(find.byType(HueWheel), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('brightness to 0 turns the light off; power on restores it', (
    WidgetTester t,
  ) async {
    final SemanticsHandle semantics = t.ensureSemantics();
    final DemoApp d = await open(t, 'Hallway');
    d.session('Hallway').setBrightness(179);
    await settle(t);
    expect(pillValue(t), '70 %');
    // Drag to the far left and let go.
    await t.drag(
      find.byKey(const ValueKey<String>('brightness')),
      const Offset(-2000, 0),
    );
    // "Off" on every frame from the release on, through the sleep fade and
    // the level stored for power-on afterwards (no pop back up).
    for (int i = 0; i < 150; i++) {
      await t.pump(const Duration(milliseconds: 16));
      expect(pillValue(t), 'Off', reason: 'frame $i');
    }
    expect(d.model('Hallway').sleeping, isTrue);
    expect(d.session('Hallway').status.state!.scene.brightness, 179);
    expect(find.text('Off'), findsOneWidget);
    // Power on: back to where it was.
    await t.tap(
      find.byWidgetPredicate(
        (Widget w) => w is GlassIconButton && w.label == 'Turn on',
      ),
    );
    await settle(t);
    expect(d.model('Hallway').sleeping, isFalse);
    expect(pillValue(t), '70 %');
    expect(find.text('70 %'), findsOneWidget);
    semantics.dispose();
    await DemoApp.shutDown(t);
  });

  testWidgets('the brightness fill is its fraction of the track, no grip', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    d.session('Desk strip').setBrightness(5); // 2 %
    await settle(t);
    final Finder track = find.descendant(
      of: find.byKey(const ValueKey<String>('brightness')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_TrackPainter',
      ),
    );
    final Size size = t.getSize(track);
    final double h = size.height;
    // About 2 % of the track (no minimum width), its end rounded only as
    // far as it is wide.
    final double w = 5 / 255 * size.width;
    expect(w / size.width, closeTo(0.02, 0.001));
    final Radius end = Radius.circular(w / 2 < h / 2 ? w / 2 : h / 2);
    // Light theme (as tested): the faint glass track, the luminous fill
    // (its body, specular highlight and inner glow) and its fine edge; no
    // grip bar after it.
    final RRect body = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, w, h),
      topRight: end,
      bottomRight: end,
    );
    expect(
      track,
      paints
        ..clipRRect()
        ..rrect(
          rrect: RRect.fromRectAndRadius(
            Offset.zero & size,
            Radius.circular(h / 2),
          ),
        )
        ..rrect(rrect: body)
        ..rect()
        ..circle()
        ..rrect(rrect: body.deflate(0.6), style: PaintingStyle.stroke),
    );
    expect(
      track,
      isNot(
        paints
          ..rrect()
          ..rrect()
          ..rrect()
          ..rrect(),
      ),
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('dragging in the colour square colours the light, no scroll', (
    WidgetTester t,
  ) async {
    // A phone-sized screen: the page can scroll.
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    await d.open(t, 'Desk strip');
    final ScrollPosition page = t
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    await t.ensureVisible(find.byType(HueWheel));
    await settle(t, 1);
    final double scrolled = page.pixels;
    final ChannelColor before = d.twin('Desk strip').color;
    final Rect wheel = t.getRect(find.byType(HueWheel));
    // Rebuilt widgets are new instances: these must survive the drag.
    final Finder screen = find.descendant(
      of: find.byType(ControlScreen),
      matching: find.byType(ListView),
    );
    final Finder editorTree = find.descendant(
      of: find.byType(ColourEditor),
      matching: find.byType(Column),
    );
    final Widget screenBefore = t.widget(screen.first);
    final Widget editorBefore = t.widget(editorTree.first);
    // Down the square's left half: less saturated, darker.
    final TestGesture g = await t.startGesture(
      wheel.center - const Offset(30, 30),
    );
    for (int i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 6));
      await t.pump(const Duration(milliseconds: 50));
    }
    // Live frames reached the light before the finger lifted, without
    // rebuilding the screen or the editor (only the colour's listeners).
    expect(d.twin('Desk strip').color, isNot(before));
    expect(identical(t.widget(screen.first), screenBefore), isTrue);
    expect(identical(t.widget(editorTree.first), editorBefore), isTrue);
    await g.up();
    await settle(t);
    expect(page.pixels, scrolled);
    final ChannelColor after = d.twin('Desk strip').color;
    expect(after.maxChannel, lessThan(before.maxChannel));
    // The editor shows what the light has (the wheel kept the finger's value).
    expect(
      t.widget<ColourEditor>(find.byType(ColourEditor)).value,
      d.session('Desk strip').status.state!.scene.color,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('effects: Solid Color on its own row, 12 effects in the grid', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    await t.tap(tab('Effects'));
    await settle(t, 1);
    final Finder grid = find.byKey(const ValueKey<String>('effects-grid'));
    final GridView g = t.widget<GridView>(grid);
    expect(
      (g.childrenDelegate as SliverChildListDelegate).children,
      hasLength(12),
    );
    expect(
      (g.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      3,
    );
    // Solid Color is above the grid, not in it.
    final Finder solid = find.byKey(const ValueKey<String>('mode-1'));
    expect(solid, findsOneWidget);
    expect(find.descendant(of: grid, matching: solid), findsNothing);
    expect(t.getRect(solid).bottom, lessThan(t.getRect(grid).top));
    // Another effect, then back to Solid Color.
    await t.tap(find.byKey(const ValueKey<String>('mode-4')));
    await settle(t);
    expect(d.twin('Desk strip').mode, 4);
    await t.tap(solid);
    await settle(t);
    expect(d.twin('Desk strip').mode, 1);
    // Every tile's glyph animates, the selected one or not.
    await t.tap(find.byKey(const ValueKey<String>('mode-6')));
    await settle(t);
    final Iterable<ModeGlyph> glyphs = t.widgetList<ModeGlyph>(
      find.descendant(of: grid, matching: find.byType(ModeGlyph)),
    );
    expect(glyphs, hasLength(12));
    expect(glyphs.every((ModeGlyph g) => g.animate), isTrue);
    expect(
      t
          .widget<ModeGlyph>(
            find.descendant(of: solid, matching: find.byType(ModeGlyph)),
          )
          .animate,
      isTrue,
    );
    // Another tab: the tiles are gone (nothing left running but the orb).
    await t.tap(tab('Colour'));
    await settle(t, 1);
    expect(find.byType(ModeGlyph), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('presets: 15 empty slots in a 3 × 5 grid', (
    WidgetTester t,
  ) async {
    await open(t, 'Living room');
    await t.tap(tab('Presets'));
    await settle(t, 1);
    for (int slot = 0; slot < 15; slot++) {
      expect(
        find.byKey(ValueKey<String>('preset-$slot')),
        findsOneWidget,
        reason: 'slot $slot',
      );
    }
    expect(find.byKey(const ValueKey<String>('preset-15')), findsNothing);
    expect(find.text('Empty'), findsNWidgets(15));
    // Three per row.
    final double row0 = t
        .getRect(find.byKey(const ValueKey<String>('preset-0')))
        .top;
    expect(t.getRect(find.byKey(const ValueKey<String>('preset-2'))).top, row0);
    expect(
      t.getRect(find.byKey(const ValueKey<String>('preset-3'))).top,
      greaterThan(row0),
    );
    await DemoApp.shutDown(t);
  });

  group('tab transitions', () {
    /// Horizontal offsets of the Transforms above [panel] (the slide).
    List<double> slides(WidgetTester t, Finder panel) => <double>[
      for (final Transform tr in t.widgetList<Transform>(
        find.ancestor(of: panel, matching: find.byType(Transform)),
      ))
        tr.transform.getTranslation().x,
    ];

    testWidgets('a new panel slides and fades in, then settles', (
      WidgetTester t,
    ) async {
      await open(t, 'Desk strip');
      final Finder wheel = find.byType(HueWheel);
      expect(wheel, findsOneWidget);
      await t.tap(tab('Effects'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      // Mid-switch: both panels, the new one arriving from the right.
      final Finder grid = find.byKey(const ValueKey<String>('effects-grid'));
      expect(grid, findsOneWidget);
      expect(wheel, findsOneWidget);
      expect(slides(t, grid).any((double x) => x > 0 && x <= 12), isTrue);
      // Through Motion.medium: no exceptions, the new panel in place.
      for (int ms = 40; ms < Motion.medium.inMilliseconds; ms += 16) {
        await t.pump(const Duration(milliseconds: 16));
        expect(t.takeException(), isNull);
      }
      expect(grid, findsOneWidget);
      await settle(t, 1);
      expect(wheel, findsNothing);
      expect(slides(t, grid).every((double x) => x == 0), isTrue);
      // Back to an earlier tab: it arrives from the left.
      await t.tap(tab('Colour'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      expect(slides(t, wheel).any((double x) => x < 0 && x >= -12), isTrue);
      await settle(t, 1);
      expect(grid, findsNothing);
      await DemoApp.shutDown(t);
    });

    testWidgets('under Reduce Motion the switch completes in one frame', (
      WidgetTester t,
    ) async {
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await open(t, 'Desk strip');
      await t.tap(tab('Effects'));
      await t.pump();
      final Finder grid = find.byKey(const ValueKey<String>('effects-grid'));
      expect(grid, findsOneWidget);
      expect(find.byType(HueWheel), findsNothing);
      expect(slides(t, grid).every((double x) => x == 0), isTrue);
      await DemoApp.shutDown(t);
    });
  });

  testWidgets('a saved preset pulses its tile', (WidgetTester t) async {
    final DemoApp d = await open(t, 'Living room');
    await t.tap(tab('Presets'));
    await settle(t, 1);
    final Finder slot = find.byKey(const ValueKey<String>('preset-0'));
    double scaleOf() => t
        .widget<Transform>(
          find.descendant(of: slot, matching: find.byType(Transform)).first,
        )
        .transform
        .getMaxScaleOnAxis();
    expect(scaleOf(), 1);
    await t.tap(slot);
    await settle(t, 1);
    await t.tap(find.text('Save'));
    // The light stores it, then the tile bumps up and back.
    double peak = 1;
    for (int i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16));
      peak = peak > scaleOf() ? peak : scaleOf();
    }
    expect(d.model('Living room').presetSlots, contains(0));
    expect(peak, greaterThan(1.02));
    expect(peak, lessThan(1.06));
    await settle(t, 1);
    expect(scaleOf(), closeTo(1, 0.001));
    await DemoApp.shutDown(t);
  });

  testWidgets(
    'a brightness change the light never got glides back, said once',
    (WidgetTester t) async {
      final SemanticsHandle semantics = t.ensureSemantics();
      final DemoApp d = await open(t, 'Desk strip');
      expect(pillValue(t), '100 %');
      d.radio.setAvailable('demo-rgb', available: false);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await settle(t);
      expect(
        find.byKey(const ValueKey<String>('offline-note')),
        findsOneWidget,
      );
      // Dragged while unreachable: the pill keeps it for the window...
      await t.drag(
        find.byKey(const ValueKey<String>('brightness')),
        const Offset(-120, 0),
      );
      await settle(t, 1);
      final String dragged = pillValue(t)!;
      expect(dragged, isNot('100 %'));
      await settle(t, 50);
      expect(pillValue(t), dragged);
      // ...then glides back to the light's value, with one message.
      for (int i = 0; i < 150 && pillValue(t) != '100 %'; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(pillValue(t), '100 %');
      expect(
        find.text(
          "The light couldn't be reached, so the change wasn't applied.",
        ),
        findsOneWidget,
      );
      await settle(t, 3); // the message fades
      semantics.dispose();
      await DemoApp.shutDown(t);
    },
  );
}
