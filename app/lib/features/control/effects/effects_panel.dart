import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/color/steady_colour.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_surfaces.dart';
import '../../../core/model/channel_color.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';
import '../../../sessions/fixture_session.dart';
import '../colour/colour_editor.dart';
import 'effect_colours.dart';
import 'effects_grid.dart';
import 'mode_presentation.dart';

/// The effects this light has (only those its firmware supports, shown in
/// its own colours): Solid Color as a row of its own, the others in a grid;
/// then the selected effect's sliders with the firmware's labels, its colour
/// source and the police beacons.
class EffectsPanel extends StatelessWidget {
  const EffectsPanel({
    required this.scene,
    required this.capabilities,
    required this.whitePoints,
    required this.session,
    required this.enabled,
    this.steady,
    this.animate = true,
    super.key,
  });

  final EbScene scene;
  final LightCapabilities capabilities;
  final LedWhitePoints whitePoints;
  final FixtureSession? session;
  final bool enabled;

  /// The light's colour kept steady at low channel values (for the glyphs).
  final SteadyLevels? steady;

  /// The effects move only while the light is on and connected; otherwise
  /// they show their still frames.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<EbModeSpec> modes = presentModes(capabilities, whitePoints, l);
    final EbModeSpec? current = modes
        .where((EbModeSpec m) => m.id == scene.mode)
        .firstOrNull;
    final Color colour = swatchOf(scene.color, whitePoints, steady: steady);
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    final FixtureSession? s = enabled ? session : null;
    void select(int mode) {
      if (s != null) unawaited(s.setMode(mode));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        EffectsGrid(
          modes: modes,
          selected: scene.mode,
          color: colour,
          animate: animate,
          onSelect: select,
        ),
        if (capabilities.layout == ChannelLayout.w &&
            !capabilities.supportsMode(10))
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Text(
              l.modeUnavailableRainbow,
              style: TextStyle(
                color: fg.withValues(
                  alpha: LightSurfaces.dim(0.6, dark: fg == Colors.white),
                ),
                fontSize: 13,
              ),
            ),
          ),
        ModeSettingsSwitcher(
          mode:
              current != null &&
                  (current.hasSpeed ||
                      current.hasFrequency ||
                      current.hasColorMode)
              ? current
              : null,
          builder: (EbModeSpec mode) => _ModeSettings(
            mode: mode,
            scene: scene,
            whitePoints: whitePoints,
            session: s,
            fg: fg,
          ),
        ),
      ],
    );
  }
}

class _ModeSettings extends StatelessWidget {
  const _ModeSettings({
    required this.mode,
    required this.scene,
    required this.whitePoints,
    required this.session,
    required this.fg,
  });

  final EbModeSpec mode;
  final EbScene scene;
  final LedWhitePoints whitePoints;
  final FixtureSession? session;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final FixtureSession? s = session;
    final EbColorModeKind? kind = mode.colorModeKind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ModeSliders(
          mode: mode,
          speed: scene.speeds[mode.id - 1],
          frequency: scene.frequencies[mode.id - 1],
          enabled: s != null,
          fg: fg,
          onSpeed: (int v) => unawaited(s?.setSpeed(mode.id, v)),
          onFrequency: (int v) => unawaited(s?.setFrequency(mode.id, v)),
        ),
        if (kind != null) ...<Widget>[
          const SizedBox(height: Space.m),
          ColourSourceControl(
            kind: kind,
            layout: scene.layout,
            selected: scene.colorMode(kind),
            fg: fg,
            onChanged: (int v) => unawaited(s?.setColorMode(kind, v)),
          ),
          if (kind == EbColorModeKind.police &&
              scene.colorMode(kind) == 0) ...<Widget>[
            const SizedBox(height: Space.m),
            Row(
              children: <Widget>[
                for (final EbPoliceSlot slot in EbPoliceSlot.values)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: slot == EbPoliceSlot.a ? Space.xs : 0,
                        left: slot == EbPoliceSlot.b ? Space.xs : 0,
                      ),
                      child: BeaconSwatch(
                        label: slot == EbPoliceSlot.a ? l.beaconA : l.beaconB,
                        color: swatchOf(scene.police(slot), whitePoints),
                        fg: fg,
                        onTap: s == null
                            ? null
                            : () => unawaited(
                                showBeaconSheet(
                                  context,
                                  title: slot == EbPoliceSlot.a
                                      ? l.beaconA
                                      : l.beaconB,
                                  start: scene.police(slot),
                                  whitePoints: whitePoints,
                                  onChanged: (ChannelColor c, _) =>
                                      unawaited(s.setPoliceColor(slot, c)),
                                ),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}
