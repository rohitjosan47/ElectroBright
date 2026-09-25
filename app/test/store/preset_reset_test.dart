import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/store/preset_reset.dart';
import 'package:electrobright/features/control/presets/preset_meta.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Firmware 3.6.0 clears the presets on every light once; the app drops its
/// own preset names and snapshots once to match. Nothing is migrated.
void main() {
  Map<String, Object?> oldPresets() => <String, Object?>{
    'f-light': <String, Object?>{
      '3': <String, Object?>{'name': 'Cozy'},
      '20': <String, Object?>{'name': 'Beyond 15'},
    },
  };

  Map<String, Object?> settingsOf(JsonStore s) =>
      s.read('settings')! as Map<String, Object?>;

  group('PresetReset.run', () {
    test('empties presetMeta once and keeps everything else', () {
      final JsonStore store = JsonStore.memory()
        ..write('presetMeta', oldPresets())
        ..write('settings', <String, Object?>{'onboarded': true})
        ..write('fixtures', <Object?>['kept'])
        ..write('lastKnown', <String, Object?>{'f-light': 'kept'});
      expect(PresetReset.run(store), isTrue);
      expect(store.read('presetMeta'), <String, Object?>{});
      expect(settingsOf(store)[PresetReset.doneFlag], isTrue);
      expect(settingsOf(store)['onboarded'], isTrue);
      expect(store.read('fixtures'), <Object?>['kept']);
      expect(store.read('lastKnown'), <String, Object?>{'f-light': 'kept'});

      // A preset saved afterwards survives the next start.
      final Map<String, Object?> saved = <String, Object?>{
        'f-light': <String, Object?>{
          '0': <String, Object?>{'name': 'New'},
        },
      };
      store.write('presetMeta', saved);
      expect(PresetReset.run(store), isFalse);
      expect(store.read('presetMeta'), saved);
    });

    test('a store with no presets and no settings is marked too', () {
      final JsonStore store = JsonStore.memory();
      expect(PresetReset.run(store), isTrue);
      expect(settingsOf(store)[PresetReset.doneFlag], isTrue);
    });
  });

  group('app start', () {
    Widget app(JsonStore main, JsonStore demo) => ProviderScope(
      retry: (int retryCount, Object error) => null,
      overrides: [
        servicesProvider.overrideWithValue(AppServices()),
        storeProvider.overrideWithValue(main),
        demoStoreProvider.overrideWithValue(() async => demo),
        legacyPrefsProvider.overrideWithValue(() async => null),
      ],
      child: const ElectroBrightApp(),
    );

    testWidgets(
      'old preset data is gone after the first start, and only then',
      (WidgetTester t) async {
        final JsonStore main = JsonStore.memory();
        final JsonStore demo = JsonStore.memory()
          ..write('presetMeta', oldPresets());
        await t.pumpWidget(app(main, demo));
        await t.pump();
        await t.tap(find.text('Try demo lights'));
        await DemoApp.settle(t, 1);
        expect(find.text('Lights'), findsOneWidget);
        expect(demo.read('presetMeta'), <String, Object?>{});
        expect(settingsOf(demo)[PresetReset.doneFlag], isTrue);

        // A preset saved since, then the app starts again (resuming demo).
        final Map<String, Object?> saved = <String, Object?>{
          'f-light': <String, Object?>{
            '0': <String, Object?>{'name': 'New'},
          },
        };
        demo.write('presetMeta', saved);
        await DemoApp.shutDown(t);
        await t.pumpWidget(app(main, demo));
        await DemoApp.settle(t, 1);
        expect(find.text('Lights'), findsOneWidget);
        expect(demo.read('presetMeta'), saved);
        await DemoApp.shutDown(t);
      },
    );

    testWidgets('demo mode clears only its own store', (WidgetTester t) async {
      // The real lights' store is cleared when they start (not possible in a
      // widget test: no Bluetooth); starting demo mode leaves it alone.
      final JsonStore main = JsonStore.memory()
        ..write('presetMeta', oldPresets());
      final JsonStore demo = JsonStore.memory();
      await t.pumpWidget(app(main, demo));
      await t.pump();
      await t.tap(find.text('Try demo lights'));
      await DemoApp.settle(t, 1);
      // Demo mode clears its own store, not the real lights' data.
      expect(main.read('presetMeta'), oldPresets());
      expect(settingsOf(demo)[PresetReset.doneFlag], isTrue);
      await DemoApp.shutDown(t);
    });
  });
  testWidgets(
    'preset data beyond the light\'s 15 slots is ignored, never written',
    (WidgetTester t) async {
      final DemoApp d = await DemoApp.start(t);
      final String id = DemoApp.idOf('Kitchen');
      d.app.store.write('presetMeta', <String, Object?>{
        id: <String, Object?>{
          '3': <String, Object?>{'name': 'Kept'},
          '15': <String, Object?>{'name': 'Too far'},
          '24': <String, Object?>{'name': 'Too far'},
        },
      });
      final ProviderContainer c = ProviderScope.containerOf(
        t.element(find.text('Lights')),
      );
      final PresetMeta meta = c.read(presetMetaProvider(id));
      expect(meta.slots.keys, <int>[3]);
      c.read(presetMetaProvider(id).notifier).rename(20, 'Nope');
      c.read(presetMetaProvider(id).notifier).rename(14, 'Last');
      final Map<String, Object?> stored =
          (d.app.store.read('presetMeta')! as Map<String, Object?>)[id]!
              as Map<String, Object?>;
      expect(stored.keys.toSet(), <String>{'3', '14'});
      await DemoApp.shutDown(t);
    },
  );
}
