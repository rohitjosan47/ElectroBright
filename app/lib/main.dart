import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Async disk-to-RAM shader preload only; no GPU work before the first frame.
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  runApp(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: ProviderScope(
        // Reconnection and retries belong to the ConnectionManager, never to
        // Riverpod's automatic provider retry.
        retry: (int retryCount, Object error) => null,
        child: const ElectroBrightApp(),
      ),
    ),
  );
}
