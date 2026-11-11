import 'dart:async';

import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/store/legacy_import.dart';
import 'package:electrobright/core/store/preset_reset.dart';
import 'package:electrobright/features/developer/developer_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/features/onboarding/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/demo_app.dart';

void main() {
  testWidgets('Reset app erases everything and returns to onboarding', (
    WidgetTester t,
  ) async {
    final DemoApp demo = await DemoApp.start(t);
    final ProviderContainer c = ProviderScope.containerOf(
      t.element(find.byType(HomeScreen)),
    );
    final JsonStore main = c.read(storeProvider);
    expect(demo.app.store.read('fixtures'), isNotNull);

    unawaited(
      Navigator.of(
        t.element(find.byType(HomeScreen)),
      ).push(MaterialPageRoute<void>(builder: (_) => const DeveloperScreen())),
    );
    await DemoApp.settle(t, 1);

    // Cancelling keeps everything.
    final Finder reset = find.byKey(const ValueKey<String>('dev-reset-app'));
    await t.scrollUntilVisible(
      reset,
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await t.ensureVisible(reset);
    await DemoApp.settle(t, 1);
    await t.tap(reset);
    await DemoApp.settle(t, 1);
    await t.tap(find.text('Cancel'));
    await DemoApp.settle(t, 1);
    expect(find.byType(DeveloperScreen), findsOneWidget);
    expect(c.read(appSessionProvider), isNotNull);

    await t.tap(reset);
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('dev-reset-app-confirm')));
    await DemoApp.settle(t, 1);
    // Shutting the session down also waits on real (not fake) time.
    for (int i = 0; i < 100 && demo.app.store.read('fixtures') != null; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(DeveloperScreen), findsNothing);
    expect(c.read(appSessionProvider), isNull);
    expect(c.read(appSessionProvider.notifier).onboarded, isFalse);
    expect(demo.app.store.read('fixtures'), isNull);
    // Only the one-time migration flags survive.
    final Map<String, Object?> settings =
        main.read('settings')! as Map<String, Object?>;
    expect(
      settings.keys,
      everyElement(isIn(<String>[LegacyImport.doneFlag, PresetReset.doneFlag])),
    );
  });
}
