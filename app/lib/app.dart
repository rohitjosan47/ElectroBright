import 'package:flutter/material.dart';

import 'bootstrap/service_registry.dart';
import 'design/glass/glass_surface.dart';
import 'design/haptics/haptics_scope.dart';

import 'design/theme/app_theme.dart';
import 'design/gallery/gallery.dart';
import 'features/diagnostics/ble_lab.dart';
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
          : const _HomePlaceholder(),
    );
  }
}

/// Stand-in until the Home connection panel lands (M4).
class _HomePlaceholder extends StatelessWidget {
  const _HomePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Text(
            AppLocalizations.of(context).lightsTitle,
            style: Theme.of(context).textTheme.displaySmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          FloatingActionButton.extended(
            heroTag: 'gallery',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ComponentGallery()),
            ),
            label: const Text('Design gallery'),
            icon: const Icon(Icons.palette_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'lab',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const BleLabScreen()),
            ),
            label: const Text('BLE Lab'),
            icon: const Icon(Icons.science_outlined),
          ),
        ],
      ),
    );
  }
}
