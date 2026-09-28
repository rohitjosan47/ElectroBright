import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bootstrap/service_registry.dart';
import 'design/glass/glass_surface.dart';
import 'design/haptics/haptics_scope.dart';

import 'design/theme/app_theme.dart';
import 'design/gallery/gallery.dart';
import 'app/app_session.dart';
import 'design/canvas/ambient_canvas.dart';
import 'features/home/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'l10n/app_localizations.dart';

class ElectroBrightApp extends StatelessWidget {
  const ElectroBrightApp({this.services, super.key});

  /// Null in widget tests that don't need platform services.
  final AppServices? services;

  @override
  Widget build(BuildContext context) {
    final AppServices? services = this.services;
    return MaterialApp(
      builder: (BuildContext context, Widget? child) {
        final Widget app = services == null
            ? child!
            : HapticsScope(haptics: services.haptics, child: child!);
        final ValueNotifier<bool>? solid =
            services?.platform.reduceTransparency;
        if (solid == null) return GlassPolicy(child: app);
        return ValueListenableBuilder<bool>(
          valueListenable: solid,
          builder: (BuildContext context, bool reduce, _) => GlassPolicy(
            solid: reduce || MediaQuery.highContrastOf(context),
            child: app,
          ),
        );
      },
      onGenerateTitle: (BuildContext context) =>
          AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // `--dart-define=EB_START=gallery` opens the component gallery directly
      // (screenshots and design review).
      home: const String.fromEnvironment('EB_START') == 'gallery'
          ? const ComponentGallery()
          : const _Root(),
    );
  }
}

/// Onboarding until the user picked real or demo lights, then Home. Saves
/// every light's state and releases lights when the app goes to background.
class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> {
  late final AppLifecycleListener _lifecycle;

  AppLifecycleListener _listen() => AppLifecycleListener(
    onPause: () {
      unawaited(ref.read(appSessionProvider.notifier).saveAll());
      final AppSession? app = ref.read(appSessionProvider);
      app?.ble.discovery.paused = true;
      unawaited(app?.ble.connections.onBackground());
    },
    onResume: () {
      final AppSession? app = ref.read(appSessionProvider);
      app?.ble.discovery.paused = false;
      unawaited(app?.ble.connections.onForeground());
      // Back from Settings, perhaps with Location Services switched on.
      unawaited(app?.bluetooth?.checkLocation());
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle = _listen();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSession? app = ref.watch(appSessionProvider);
    if (app != null) return const HomeScreen();
    final bool onboarded = ref.read(appSessionProvider.notifier).onboarded;
    if (!onboarded) return const OnboardingScreen();
    return const Scaffold(
      body: AmbientCanvas(
        child: Center(child: CircularProgressIndicator.adaptive()),
      ),
    );
  }
}
