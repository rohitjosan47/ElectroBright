import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'app/app_session.dart';
import 'bootstrap/service_registry.dart';
import 'core/store/json_store.dart';
import 'design/canvas/ambient_canvas.dart';
import 'design/platform/refresh_governor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Async disk-to-RAM shader preload only; no GPU work before the first frame.
  // Standard quality only: the app never renders premium glass, so its
  // shaders aren't loaded.
  await LiquidGlassWidgets.initialize(
    enablePerformanceMonitor: false,
    warmUpMode: GlassWarmUpMode.never,
  );
  prepareAmbientCanvas();
  final AppServices services = AppServices();
  await services.platform.init();
  // Android: a high refresh rate only while something moves or a finger is
  // down (iOS adapts on its own).
  if (Platform.isAndroid) {
    RefreshGovernor(services.platform.setHighRefreshRate).start();
  }
  final Directory support = await getApplicationSupportDirectory();
  final JsonStore store = await JsonStore.open(
    Directory('${support.path}/store'),
  );
  runApp(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: ProviderScope(
        // Reconnection and retries belong to the ConnectionManager, never to
        // Riverpod's automatic provider retry.
        retry: (int retryCount, Object error) => null,
        overrides: [
          servicesProvider.overrideWithValue(services),
          storeProvider.overrideWithValue(store),
          demoStoreProvider.overrideWithValue(
            () => JsonStore.open(Directory('${support.path}/store-demo')),
          ),
        ],
        child: ElectroBrightApp(services: services),
      ),
    ),
  );
}
