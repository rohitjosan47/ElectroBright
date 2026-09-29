import 'package:electrobright/design/gallery/gallery.dart';
import 'package:electrobright/design/glass/glass_surface.dart';
import 'package:electrobright/design/theme/app_theme.dart';
import 'package:electrobright/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final bool dark in <bool>[false, true]) {
    for (final double scale in <double>[1, 2]) {
      testWidgets('gallery renders (dark=$dark, text ${scale}x)', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        tester.view.physicalSize = const Size(1179, 2556);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
        _expectClean(tester);
        expect(find.bySemanticsLabel(RegExp('^Brightness')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('^Colour')), findsWidgets);
        // Scroll through the whole gallery so every section lays out.
        await tester.drag(find.byType(ListView), const Offset(0, -3000));
        await tester.pump(const Duration(milliseconds: 600));
        _expectClean(tester);
        semantics.dispose();
      });
    }
  }
}

void _expectClean(WidgetTester tester) {
  final Object? e = tester.takeException();
  if (e is FlutterError) fail(e.toStringDeep());
  expect(e, isNull);
}
