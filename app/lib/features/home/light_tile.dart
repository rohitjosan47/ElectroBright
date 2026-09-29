import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/bluetooth_access.dart';
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
import '../control/effects/mode_presentation.dart';
import '../firmware_update/update_providers.dart';
import 'presence.dart';

/// One saved light on Home: colour orb, name, type, state, presence, power.
class LightTile extends ConsumerWidget {
  const LightTile({
    required this.fixtureId,
    required this.onOpen,
    required this.onMore,
    this.onUpdate,
    super.key,
  });

  final String fixtureId;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  /// Opens the light's firmware update (its update badge).
  final VoidCallback? onUpdate;

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
      bool updating,
    ) = ref.watch(
      fixtureStatusProvider(fixtureId).select(
        (FixtureStatus s) => (s.state, s.phase, s.incompatibility, s.updating),
      ),
    );
    final bool update = ref.watch(updateAvailableProvider(fixtureId));
    // No fixture type yet: "Setup needed" instead of its state; a tap sets
    // it up.
    final bool setup =
        f.setupNeeded || incompatibility == EbIncompatibility.setupNeeded;
    final String presence = setup
        ? l.presenceSetupNeeded
        : presenceOf(
            l,
            phase,
            incompatibility,
            updating: updating,
            bluetooth: ref.watch(bluetoothIssueProvider),
          );
    final EbScene? scene = setup ? null : state?.scene;
    final bool sleeping = state?.sleeping ?? false;
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);

    final ({Color color, bool glow}) orb = tileColour(
      ref,
      f,
      setup ? null : state,
      fg,
    );
    final String mode = scene == null
        ? ''
        : modeName(EbModeCatalog.byId(scene.mode), f.layout, l);
    final bool live = phase == LinkPhase.ready && !updating;

    return Semantics(
      button: true,
      label: setup ? f.name : '${f.name}, ${fixtureTypeName(l, f.layout)}',
      value: presence,
      hint: l.lightTileHint,
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
                  Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      TileOrb(color: orb.color, glow: orb.glow),
                      if (update)
                        Positioned(
                          right: -6,
                          top: -6,
                          child: UpdateBadge(onTap: onUpdate),
                        ),
                    ],
                  ),
                  const Spacer(),
                  GlassIconButton(
                    icon: Icons.power_settings_new_rounded,
                    label: sleeping ? l.powerOn : l.powerOff,
                    size: 40,
                    active: live && !sleeping,
                    haptic: sleeping
                        ? HapticEvent.powerOn
                        : HapticEvent.powerOff,
                    onPressed: scene == null || updating
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
              if (setup)
                const SetupNeededBadge()
              else
                FixtureTypeBadge(layout: f.layout, whitePoints: f.whitePoints),
              const SizedBox(height: Space.xs),
              Text(
                scene == null
                    ? presence
                    : stateLine(l, scene, sleeping: sleeping, modeName: mode),
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

/// A light's colour as Home shows it: its look at full intensity, glowing;
/// a faint disc while it is off or its state is unknown.
({Color color, bool glow}) tileColour(
  WidgetRef ref,
  Fixture f,
  EbDeviceState? state,
  Color fg,
) {
  final EbScene? scene = state?.scene;
  final DisplayColor? dc = scene == null
      ? null
      : DisplayColor.ofScene(
          scene,
          sleeping: state!.sleeping,
          whitePoints: f.whitePoints,
          steady: ref.watch(steadyLevelsProvider(f.id)),
        );
  return dc == null || dc.off
      ? (color: fg.withValues(alpha: 0.12), glow: false)
      : (color: Color(ColorScience.toArgb(dc.color)), glow: true);
}

/// The update badge on a Home tile's orb: the light's firmware is older
/// than the app's. Brand periwinkle (never the light's colour), like the
/// pills; a tap opens the update.
class UpdateBadge extends StatelessWidget {
  const UpdateBadge({this.onTap, super.key});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.darkOf(context);
    final Color fill = dark ? PillFill.dark.halo : PillFill.light.halo;
    return Semantics(
      button: onTap != null,
      label: l.updateFirmware,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey<String>('tile-update-badge'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          // A bigger target than the dot.
          padding: const EdgeInsets.all(4),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: Border.all(
                color: dark ? const Color(0xFF15171C) : Colors.white,
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.arrow_upward_rounded,
              size: 12,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// The round colour swatch of a light on Home.
class TileOrb extends StatelessWidget {
  const TileOrb({
    required this.color,
    required this.glow,
    this.size = 44,
    super.key,
  });
  final Color color;
  final bool glow;
  final double size;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Motion.medium,
    width: size,
    height: size,
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
