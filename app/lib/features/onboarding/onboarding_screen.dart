import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/components/aura_add_button.dart';
import '../../app/app_session.dart';
import '../../design/canvas/ambient_canvas.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../developer/developer_screen.dart' show DeveloperCredit;

/// The app icon artwork, matching the system appearance, with the same
/// continuous rounded corners as an iOS home-screen icon.
class _BrandLogo extends StatelessWidget {
  const _BrandLogo({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        shape: ContinuousRectangleBorder(
          borderRadius: BorderRadius.circular(size * 0.45),
        ),
        shadows: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.5 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(
          shape: ContinuousRectangleBorder(
            borderRadius: BorderRadius.circular(size * 0.45),
          ),
        ),
        child: Image.asset(
          dark ? 'assets/brand/logo_dark.png' : 'assets/brand/logo_light.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

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
            // The bottom edge is left to the credit, which sits on its own
            // below the actions instead of inside the gutter.
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.gutter,
              Space.gutter,
              Space.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 3 : 2 : 1 keeps the brand block a little above centre and
                // lifts the actions off the bottom, leaving room for the credit.
                const Spacer(flex: 3),
                const Center(child: _BrandLogo(size: 112)),
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
                const Spacer(flex: 2),
                AuraButton(
                  onPressed: () => unawaited(c.useMyLights()),
                  child: Text(l.useMyLights),
                ),
                const SizedBox(height: Space.s),
                TextButton(
                  onPressed: () => unawaited(c.start(demo: true)),
                  child: Text(l.tryDemo),
                ),
                const Spacer(),
                const DeveloperCredit(subtle: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
