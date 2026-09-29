import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/glass/glass_surface.dart';
import 'package:electrobright/design/theme/app_theme.dart';
import 'package:electrobright/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// At the largest accessibility text size (iOS AX5, about 3.1x) the
/// segmented control's labels and the timer dial's text scale down to fit,
/// on one line, instead of spilling out of their shapes.
void main() {
  const double largest = 3.1;

  Future<void> pump(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(393, 852);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(largest),
            disableAnimations: true,
          ),
          child: GlassPolicy(solid: true, child: child!),
        ),
        home: Scaffold(
          body: Center(child: SizedBox(width: 353, child: child)),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 600));
  }

  /// [text] is drawn on one line inside [box], and smaller than asked.
  void expectFits(WidgetTester t, String text, Rect box) {
    final Rect r = t.getRect(find.text(text));
    expect(
      r.left >= box.left - 0.5 && r.right <= box.right + 0.5,
      isTrue,
      reason: '"$text" $r fits across $box',
    );
    expect(r.top >= box.top - 0.5 && r.bottom <= box.bottom + 0.5, isTrue);
    final Size laidOut = t.renderObject<RenderBox>(find.text(text)).size;
    expect(r.width, lessThan(laidOut.width), reason: '"$text" scaled down');
    expect(t.takeException(), isNull);
  }

  testWidgets('segmented labels scale down to fit their segments', (
    WidgetTester t,
  ) async {
    const List<(int, String)> tabs = <(int, String)>[
      (0, 'Colour'),
      (1, 'Effects'),
      (2, 'Presets'),
    ];
    await pump(
      t,
      GlassSegmented<int>(segments: tabs, selected: 0, onChanged: (_) {}),
    );
    final Rect track = t.getRect(find.byType(GlassSegmented<int>));
    final double w = (track.width - 2 * GlassSegmented.inset) / tabs.length;
    for (int i = 0; i < tabs.length; i++) {
      final double left = track.left + GlassSegmented.inset + i * w;
      expectFits(
        t,
        tabs[i].$2,
        Rect.fromLTWH(left, track.top, w, track.height),
      );
    }
  });

  testWidgets('the timer dial text scales down to fit inside the ring', (
    WidgetTester t,
  ) async {
    await pump(
      t,
      Center(
        child: SizedBox.square(
          dimension: 240,
          child: TimerDial(
            steps: const <Duration>[Duration(minutes: 30), Duration(hours: 1)],
            index: 0,
            label: (Duration d) => 'Off in 1:02:03',
            progress: 0.5,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final Rect dial = t.getRect(find.byType(TimerDial));
    // Inside the detent dots (radius r - 18 with r = s / 2 - 14).
    final double inner = dial.width / 2 - 32;
    expectFits(
      t,
      'Off in 1:02:03',
      Rect.fromCircle(center: dial.center, radius: inner),
    );
  });
}
