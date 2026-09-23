import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'bootstrap/service_registry.dart';
import 'design/canvas/ambient_canvas.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Async disk-to-RAM shader preload only; no GPU work before the first frame.
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  prepareAmbientCanvas();
  final AppServices services = AppServices();
  await services.platform.init();
  runApp(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: ProviderScope(
        // Reconnection and retries belong to the ConnectionManager, never to
        // Riverpod's automatic provider retry.
        retry: (int retryCount, Object error) => null,
        overrides: [servicesProvider.overrideWithValue(services)],
        child: ElectroBrightApp(services: services),
      ),
    ),
  );
}
