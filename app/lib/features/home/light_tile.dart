import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/color/color_science.dart';
import '../../core/color/light_tone.dart';
import '../../core/model/fixture.dart';
import '../../core/protocol/eb/eb_scene.dart';
import '../../core/protocol/eb/mode_catalog.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/fixture_session.dart';
import 'presence.dart';

/// One saved light on Home: colour orb, name, type, state, presence, power.
class LightTile extends ConsumerWidget {
  const LightTile({
    required this.fixtureId,
    required this.onOpen,
    required this.onMore,
    super.key,
  });

  final String fixtureId;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture? f = ref.watch(fixtureProvider(fixtureId));
    if (f == null) return const SizedBox.shrink();
    // Only what the tile shows: not rebuilt for a change it doesn't show.
    final (
      EbDeviceState? state,
      LinkPhase phase,
      EbIncompatibility? incompatibility,
    ) = ref.watch(
      fixtureStatusProvider(fixtureId)
          .select((FixtureStatus s) => (s.state, s.phase, s.incompatibility)),
    );
    final String presence = presenceOf(l, phase, incompatibility);
    final EbScene? scene = state?.scene;
    final bool sleeping = state?.sleeping ?? false;
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);

    final DisplayColor? dc = scene == null
        ? null
        : DisplayColor.ofScene(
            scene,
            sleeping: sleeping,
            whitePoints: f.whitePoints,
            steady: ref.watch(steadyLevelsProvider(fixtureId)),
          );
    final Color orb = dc == null || dc.off
        ? fg.withValues(alpha: 0.12)
        : Color(ColorScience.toArgb(dc.color));
    final String modeName = scene == null
        ? ''
        : EbModeCatalog.byId(scene.mode).name;
    final bool live = phase == LinkPhase.ready;

    return Semantics(
      button: true,
      label: '${f.name}, ${fixtureTypeName(l, f.layout)}',
      value: presence,
      child: GestureDetector(
        onTap: onOpen,
        onLongPress: () {
          HapticsScope.of(context).play(HapticEvent.longPress);
          onMore();
        },
        child: GlassSurface(
          radius: Radii.large,
          padding: const EdgeInsets.all(Space.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _Orb(color: orb, glow: dc != null && !dc.off),
                  const Spacer(),
                  GlassIconButton(
                    icon: Icons.power_settings_new_rounded,
                    label: sleeping ? l.powerOn : l.powerOff,
                    size: 40,
                    active: live && !sleeping,
                    haptic: sleeping
                        ? HapticEvent.powerOn
                        : HapticEvent.powerOff,
                    onPressed: scene == null
                        ? null
                        : () => unawaited(_togglePower(ref, !sleeping)),
                  ),
                ],
              ),
              const SizedBox(height: Space.s),
              Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Space.xxs),
              FixtureTypeBadge(layout: f.layout, whitePoints: f.whitePoints),
              const SizedBox(height: Space.xs),
              Text(
                scene == null
                    ? presence
                    : stateLine(
                        l,
                        scene,
                        sleeping: sleeping,
                        modeName: modeName,
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg.withValues(alpha: 0.8),
                  fontSize: 13,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              if (scene != null)
                Text(
                  presence,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg.withValues(alpha: live ? 0.55 : 0.45),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Power from Home: connects if needed (the light is wanted for the action).
  Future<void> _togglePower(WidgetRef ref, bool off) async {
    final AppSession? app = ref.read(appSessionProvider);
    final FixtureSession? s = app?.ble.connections.session(fixtureId);
    if (app == null || s == null) return;
    final Want w = app.ble.connections.want(fixtureId, WantReason.action);
    try {
      await s.setPower(on: !off);
    } finally {
      w.release();
    }
  }
}

class _Orb extends StatelessWidget {
  const _Orb({required this.color, required this.glow});
  final Color color;
  final bool glow;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Motion.medium,
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: <Color>[Color.lerp(color, Colors.white, 0.35)!, color],
      ),
      boxShadow: glow
          ? <BoxShadow>[
              BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 18),
            ]
          : const <BoxShadow>[],
    ),
  );
}
