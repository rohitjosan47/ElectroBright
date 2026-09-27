// Idle activity: how much the app does while nothing changes on screen, in
// demo mode on a 120 Hz frame clock. Frames requested, running tickers, the
// BLE scan held, rebuilds and repaints, status emits and store writes per
// scenario. The numbers are written to build/perf/idle_activity.txt; the
// assertions pin the behaviour each scenario must keep.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/control/timer_sheet.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// One scenario's numbers over its window.
final class Activity {
  Activity(this.name);
  final String name;
  double framesPerSecond = 0;
  int tickers = 0;
  String scan = 'none';
  double homeBuildsPerSecond = 0;
  double countdownBuildsPerSecond = 0;
  double rebuildsPerFrame = 0;
  double paintsPerFrame = 0;
  double statusEmitsPerSecond = 0;
  double storeWritesPerSecond = 0;

  static String header() =>
      '${'scenario'.padRight(40)} fps  tick  scan       home/s  count/s '
      'rebuild/f paint/f status/s writes/s';

  String row() =>
      '${name.padRight(40)} ${framesPerSecond.toStringAsFixed(0).padLeft(3)}  '
      '${tickers.toString().padLeft(4)}  ${scan.padRight(9)}  '
      '${homeBuildsPerSecond.toStringAsFixed(1).padLeft(6)}  '
      '${countdownBuildsPerSecond.toStringAsFixed(1).padLeft(6)}  '
      '${rebuildsPerFrame.toStringAsFixed(1).padLeft(8)} '
      '${paintsPerFrame.toStringAsFixed(1).padLeft(7)} '
      '${statusEmitsPerSecond.toStringAsFixed(1).padLeft(8)} '
      '${storeWritesPerSecond.toStringAsFixed(1).padLeft(8)}';
}

final List<Activity> _results = <Activity>[];

/// 120 Hz frame clock.
const Duration _vsync = Duration(microseconds: 8333);

/// Measures [window] of app time, one pump per vsync; [onFrame] runs before
/// each pump (a finger moving, for drags).
Future<Activity> measure(
  WidgetTester t,
  DemoApp d,
  String name, {
  Duration window = const Duration(seconds: 1),
  String? light,
  Future<void> Function(int frame)? onFrame,
}) async {
  final Activity a = Activity(name);
  int homeBuilds = 0, countdownBuilds = 0, rebuilds = 0, paints = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    rebuilds++;
    if (e.widget is HomeScreen) homeBuilds++;
    if (e.widget is TimerCountdown) countdownBuilds++;
  };
  debugOnProfilePaint = (RenderObject _) => paints++;
  int emits = 0;
  // Status notifications as the UI sees them (the app's own provider).
  final ProviderContainer c = ProviderScope.containerOf(
    t.element(find.byType(MaterialApp).first),
    listen: false,
  );
  final List<ProviderSubscription<FixtureStatus>> subs =
      <ProviderSubscription<FixtureStatus>>[
        for (final String n
            in light == null ? DemoApp.lights.keys : <String>[light])
          c.listen(fixtureStatusProvider(DemoApp.idOf(n)), (_, _) => emits++),
      ];
  final JsonStore store = c.read(storeProvider);
  final int writes0 = store.writes;
  final int steps = window.inMicroseconds ~/ _vsync.inMicroseconds;
  int frames = 0, tickers = 0;
  // One pump per vsync. The engine would draw a frame at a vsync only when
  // something asked for one: a running ticker (it asks every vsync), or work
  // done in it (a rebuild or a repaint, e.g. after an advert or a status).
  for (int i = 0; i < steps; i++) {
    await onFrame?.call(i);
    final bool ticking = t.binding.transientCallbackCount > 0;
    tickers = math.max(tickers, t.binding.transientCallbackCount);
    final int r0 = rebuilds, p0 = paints;
    await t.pump(_vsync);
    // No frames at all while the app is hidden or paused (the engine stops
    // them); the test binding pumps anyway.
    if (t.binding.framesEnabled &&
        (ticking || rebuilds != r0 || paints != p0)) {
      frames++;
    }
  }
  final double seconds = window.inMicroseconds / 1e6;
  for (final ProviderSubscription<FixtureStatus> s in subs) {
    s.close();
  }
  debugOnRebuildDirtyWidget = null;
  debugOnProfilePaint = null;
  final Discovery discovery = d.app.ble.discovery;
  a
    ..framesPerSecond = frames / seconds
    ..tickers = math.max(tickers, t.binding.transientCallbackCount)
    ..scan = discovery.isScanning
        ? (discovery.strongestNeed?.name ?? 'on')
        : 'none'
    ..homeBuildsPerSecond = homeBuilds / seconds
    ..countdownBuildsPerSecond = countdownBuilds / seconds
    ..rebuildsPerFrame = frames == 0 ? 0 : rebuilds / frames
    ..paintsPerFrame = frames == 0 ? 0 : paints / frames
    ..statusEmitsPerSecond = emits / seconds
    ..storeWritesPerSecond = (store.writes - writes0) / seconds;
  _results.add(a);
  return a;
}

Future<void> tapTab(WidgetTester t, String tab) async {
  await t.tap(find.text(tab).first);
  await DemoApp.settle(t, 2);
}

/// Only the lights that are connected stay available, and the demo's
/// unsaved legacy light goes away: nothing advertises.
void quiet(DemoApp d) {
  d.radio.setAvailable('demo-legacy', available: false);
  for (final MapEntry<String, (String, dynamic)> e in DemoApp.lights.entries) {
    if (d.session(e.key).status.phase != LinkPhase.ready) {
      d.radio.setAvailable(e.value.$1, available: false);
    }
  }
}

void main() {
  tearDownAll(() {
    final String table = <String>[
      Activity.header(),
      for (final Activity a in _results) a.row(),
    ].join('\n');
    File('build/perf/idle_activity.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('$table\n');
    // ignore: avoid_print
    print('\n$table');
  });

  Future<DemoApp> start(WidgetTester t) async {
    // 1x: the counts do not depend on resolution, and it renders faster.
    t.view.physicalSize = const Size(393, 852);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    await DemoApp.settle(t, 3);
    return d;
  }

  testWidgets('home, adverts from unconnected lights', (WidgetTester t) async {
    final DemoApp d = await start(t);
    final Activity a = await measure(t, d, 'home, lights advertising');
    // Adverts that change nothing Home shows don't rebuild it (item 2).
    expect(a.homeBuildsPerSecond, 0);
    expect(a.framesPerSecond, 0);
    expect(a.scan, 'addFlow');
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('home, quiet', (WidgetTester t) async {
    final DemoApp d = await start(t);
    quiet(d);
    await DemoApp.settle(t, 1);
    await measure(t, d, 'home, quiet');
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('control screen idle, light on, Solid', (WidgetTester t) async {
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await d.session('Living room').setMode(EbModeCatalog.solid);
    await DemoApp.settle(t, 1);
    for (final String tab in <String>['Colour', 'Effects', 'Presets']) {
      await tapTab(t, tab);
      final Activity a = await measure(
        t,
        d,
        'control on, Solid, $tab',
        light: 'Living room',
      );
      // The static Solid orb doesn't tick (item 1); only the Effects tiles
      // do. Home's add-flow scan stops under the control screen (item 3).
      if (tab == 'Effects') {
        // The tiles step at 30 Hz, one frame per step (A); no ticker runs
        // between steps.
        expect(a.tickers, 0);
        expect(a.paintsPerFrame, greaterThan(0));
        expect(a.framesPerSecond, inInclusiveRange(20, 30));
      } else {
        expect(a.tickers, 0);
        expect(a.framesPerSecond, 0);
      }
      expect(a.scan, 'none');
    }
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('control screen idle, light on, Rainbow', (WidgetTester t) async {
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await d.session('Living room').setMode(10);
    await DemoApp.settle(t, 1);
    final Activity a = await measure(
      t,
      d,
      'control on, Rainbow, Colour',
      light: 'Living room',
    );
    // The animated orb draws only when it steps: at most 30 Hz (A).
    expect(a.tickers, 0);
    expect(a.framesPerSecond, inInclusiveRange(20, 30));

    // Under a sheet it holds its frame (C).
    await t.tap(find.byIcon(Icons.timer_outlined));
    await DemoApp.settle(t, 1);
    final Activity sheet = await measure(
      t,
      d,
      'control on, Rainbow, timer sheet',
      light: 'Living room',
    );
    expect(sheet.framesPerSecond, 0);
    Navigator.of(t.element(find.byType(ControlScreen))).pop();
    await DemoApp.settle(t, 1);
    final Activity back = await measure(
      t,
      d,
      'control on, Rainbow, sheet closed',
      light: 'Living room',
    );
    expect(back.framesPerSecond, inInclusiveRange(20, 30));

    // While the app is inactive (app switcher, Control Centre) too.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final Activity inactive = await measure(
      t,
      d,
      'control on, Rainbow, app inactive',
      light: 'Living room',
    );
    expect(inactive.framesPerSecond, 0);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await DemoApp.settle(t, 1);
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('control screen idle, light off', (WidgetTester t) async {
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await d.session('Living room').setPower(on: false);
    await DemoApp.settle(t, 2);
    for (final String tab in <String>['Colour', 'Effects', 'Presets']) {
      await tapTab(t, tab);
      final Activity a = await measure(
        t,
        d,
        'control off, $tab',
        light: 'Living room',
      );
      // With the light off nothing moves, the effect tiles included: they
      // show their still frames (B).
      expect(a.tickers, 0);
      expect(a.framesPerSecond, 0);
    }
    // On again, the tiles move; gone out of range, they're still again.
    await d.session('Living room').setPower(on: true);
    await tapTab(t, 'Effects');
    final Activity on = await measure(
      t,
      d,
      'control on again, Effects',
      light: 'Living room',
    );
    expect(on.framesPerSecond, inInclusiveRange(20, 30));
    d.radio.setAvailable(DemoApp.lights['Living room']!.$1, available: false);
    // The link teardown runs on real async work.
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await DemoApp.settle(t, 3);
    expect(d.session('Living room').status.isReady, isFalse);
    final Activity gone = await measure(
      t,
      d,
      'control disconnected, Effects',
      light: 'Living room',
    );
    expect(gone.framesPerSecond, 0);
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('sheets and routes on top', (WidgetTester t) async {
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await d.session('Living room').setTimer(600);
    await DemoApp.settle(t, 1);
    await measure(t, d, 'control on, timer running', light: 'Living room');
    await t.tap(find.byIcon(Icons.timer_outlined));
    await DemoApp.settle(t, 1);
    final Activity sheet = await measure(
      t,
      d,
      'timer sheet open',
      light: 'Living room',
    );
    // Two countdowns on one clock (K; baseline: a frame each a second).
    // The Solid orb behind the sheet is still (item 1): only the
    // countdowns draw, together.
    expect(sheet.countdownBuildsPerSecond, 2);
    expect(sheet.tickers, 0);
    expect(sheet.framesPerSecond, 1);
    Navigator.of(t.element(find.byType(ControlScreen))).pop();
    await DemoApp.settle(t, 1);
    await t.tap(find.byIcon(Icons.tune_rounded));
    await DemoApp.settle(t, 1);
    final Activity covered = await measure(
      t,
      d,
      'light settings on top',
      light: 'Living room',
    );
    // The covered countdown stops (item 6; baseline 1 a second) ...
    expect(covered.countdownBuildsPerSecond, 0);
    // ... and runs again when shown.
    Navigator.of(t.element(find.byType(ControlScreen, skipOffstage: false)))
        .pop();
    await DemoApp.settle(t, 1);
    final Activity shown = await measure(
      t,
      d,
      'light settings closed',
      light: 'Living room',
    );
    expect(shown.countdownBuildsPerSecond, 1);
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('Group idle', (WidgetTester t) async {
    final DemoApp d = await start(t);
    unawaited(
      Navigator.of(t.element(find.byType(HomeScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) => const GroupScreen(kind: GroupKind.colour),
        ),
      ),
    );
    await DemoApp.settle(t, 5);
    quiet(d);
    await DemoApp.settle(t, 1);
    // Static orbs, no timer: nothing moves.
    final Activity colour = await measure(
      t,
      d,
      'Colour lights, idle, Colour tab',
    );
    expect(colour.tickers, 0);
    expect(colour.framesPerSecond, 0);
    expect(colour.scan, 'none');
    // The effect tiles step like the control screen's, nothing more.
    await tapTab(t, 'Effects');
    final Activity effects = await measure(
      t,
      d,
      'Colour lights, Effects tab, lights on',
    );
    expect(effects.tickers, 0);
    expect(effects.framesPerSecond, inInclusiveRange(20, 30));
    // Preset slots are still glass: nothing moves.
    await tapTab(t, 'Presets');
    final Activity presets = await measure(
      t,
      d,
      'Colour lights, idle, Presets tab',
    );
    expect(presets.tickers, 0);
    expect(presets.framesPerSecond, 0);
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('interactions', (WidgetTester t) async {
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await DemoApp.settle(t, 1);
    // A colour drag on the wheel's ring.
    final Rect wheel = t.getRect(find.byType(HueWheel));
    final double mid = (wheel.width < 300 ? wheel.width : 300) / 2 - 22;
    Offset ring(double deg) =>
        wheel.center + Offset.fromDirection(deg * 3.14159265 / 180, mid);
    TestGesture g = await t.startGesture(ring(0));
    await measure(
      t,
      d,
      'colour drag',
      window: const Duration(seconds: 1),
      light: 'Living room',
      onFrame: (int i) => g.moveTo(ring(i * 0.75)),
    );
    await g.up();
    await DemoApp.settle(t, 2);
    // A brightness drag.
    final Rect pill = t.getRect(
      find.byKey(const ValueKey<String>('brightness')),
    );
    g = await t.startGesture(
      Offset(pill.left + pill.width * 0.2, pill.center.dy),
    );
    await measure(
      t,
      d,
      'brightness drag',
      window: const Duration(seconds: 1),
      light: 'Living room',
      onFrame: (int i) => g.moveTo(
        Offset(pill.left + pill.width * (0.2 + i * 0.005), pill.center.dy),
      ),
    );
    await g.up();
    await DemoApp.settle(t, 2);
    // A tab switch (the second of settling after the tap).
    await t.tap(find.text('Effects').first);
    await measure(
      t,
      d,
      'tab switch (1 s after tap)',
      window: const Duration(seconds: 1),
      light: 'Living room',
    );
    expect(find.byType(GlassSlider), findsWidgets);
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('app paused', (WidgetTester t) async {
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await DemoApp.settle(t, 1);
    for (final AppLifecycleState s in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await measure(t, d, 'paused, first second', light: 'Living room');
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await DemoApp.settle(t, 25);
    final Activity paused = await measure(
      t,
      d,
      'paused, after 25 s',
      light: 'Living room',
    );
    // No frames and no scan in the background (item 3).
    expect(paused.framesPerSecond, 0);
    expect(paused.scan, 'none');
    for (final AppLifecycleState s in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    // Resuming reconnects (handshakes): let it finish before shutting down.
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await DemoApp.settle(t, 10);
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('control screen, a colour as a single step', (
    WidgetTester t,
  ) async {
    // Sanity: a colour set from outside settles back to idle.
    final DemoApp d = await start(t);
    await d.open(t, 'Living room');
    quiet(d);
    await DemoApp.settle(t, 1);
    d.session('Living room').setColor(ChannelColor.rgbw(0, 80, 255, 0));
    // The second after it: the display glides to it. Widgets that only
    // need light/dark aren't rebuilt on its steps (item 5; baseline 68
    // rebuilds a frame, the toolbar's countdown 42 a second).
    final Activity glide = await measure(
      t,
      d,
      'colour glide (1 s after a change)',
      light: 'Living room',
    );
    expect(glide.rebuildsPerFrame, lessThan(40));
    expect(glide.countdownBuildsPerSecond, 0);
    await DemoApp.settle(t, 2);
    await measure(
      t,
      d,
      'control on, after a colour change',
      light: 'Living room',
    );
    await DemoApp.shutDown(t);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
