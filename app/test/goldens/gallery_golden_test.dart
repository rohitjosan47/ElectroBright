@Tags(<String>['golden'])
library;

import 'package:electrobright/design/gallery/gallery.dart';
import 'package:electrobright/design/glass/glass_surface.dart';
import 'package:electrobright/design/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Visual baselines for the design system (plan §11/§12): both themes, 1.0x
/// and 2.0x text. Rendering differs between hosts, so goldens are only
/// compared on macOS. Update with `flutter test --update-goldens test/goldens`.
void main() {
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    for (final double scale in <double>[1, 2]) {
      testWidgets('gallery $theme ${scale}x', (WidgetTester tester) async {
        await _pumpGallery(tester, dark: dark, scale: scale);
        await expectLater(
          find.byType(ComponentGallery),
          matchesGoldenFile('gallery_${theme}_${scale.toInt()}x_top.png'),
        );
        // Start the scroll on the orb: a drag that starts on the colour wheel
        // would change the colour instead.
        await tester.dragFrom(const Offset(196, 150), const Offset(0, -1500));
        await tester.pump(const Duration(milliseconds: 600));
        await expectLater(
          find.byType(ComponentGallery),
          matchesGoldenFile('gallery_${theme}_${scale.toInt()}x_lower.png'),
        );
      });
    }
  }
}

Future<void> _pumpGallery(
  WidgetTester tester, {
  required bool dark,
  required double scale,
}) async {
  // iPhone-sized logical canvas at 1x so the files stay small.
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: GlassPolicy(solid: true, child: child!),
      ),
      home: const ComponentGallery(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 600));
}
