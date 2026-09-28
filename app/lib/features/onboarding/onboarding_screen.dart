import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../design/canvas/ambient_canvas.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../l10n/app_localizations.dart';

/// First launch: real lights (this is when the phone asks for Bluetooth) or demo
/// lights of every type, to try the app without hardware.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final AppController c = ref.read(appSessionProvider.notifier);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientCanvas(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Spacer(),
                Image.asset('assets/brand/logo_256.png', height: 96),
                const SizedBox(height: Space.xl),
                Text(
                  l.welcomeTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: Space.s),
                GlassSurface(
                  padding: const EdgeInsets.all(Space.l),
                  child: Text(l.welcomeBody, textAlign: TextAlign.center),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => unawaited(c.useMyLights()),
                  child: Text(l.useMyLights),
                ),
                const SizedBox(height: Space.s),
                TextButton(
                  onPressed: () => unawaited(c.start(demo: true)),
                  child: Text(l.tryDemo),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
