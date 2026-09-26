import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/color/colour_engine.dart';
import '../../../core/color/steady_colour.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_surfaces.dart';
import '../../../core/model/channel_color.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/components/mode_glyph.dart';
import '../../../design/controls/glass_slider.dart';
import '../../../design/glass/glass_surface.dart';
import '../../../design/haptics/haptics.dart';
import '../../../design/haptics/haptics_scope.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';
import '../../../sessions/fixture_session.dart';
import '../colour/colour_editor.dart';
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
    super.key,
  });

  final EbScene scene;
  final LightCapabilities capabilities;
  final LedWhitePoints whitePoints;
  final FixtureSession? session;
  final bool enabled;

  /// The light's colour kept steady at low channel values (for the glyphs).
  final SteadyLevels? steady;

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
    final bool large = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final bool reduced = Motion.reduced(context);
    final FixtureSession? s = enabled ? session : null;
    void select(int mode) {
      if (s != null) unawaited(s.setMode(mode));
    }

    final EbModeSpec? solid = modes
        .where((EbModeSpec m) => m.id == EbModeCatalog.solid)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (solid != null) ...<Widget>[
          _SolidRow(
            key: ValueKey<String>('mode-${solid.id}'),
            spec: solid,
            selected: scene.mode == solid.id,
            color: colour,
            fg: fg,
            onTap: () => select(solid.id),
          ),
          const SizedBox(height: Space.m),
        ],
        GridView.count(
          key: const ValueKey<String>('effects-grid'),
          crossAxisCount: large ? 2 : effectColumns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: Space.s,
          crossAxisSpacing: Space.s,
          childAspectRatio: effectTileAspect,
          children: <Widget>[
            for (final EbModeSpec m in modes)
              if (m.id != EbModeCatalog.solid)
                ModeTile(
                  key: ValueKey<String>('mode-${m.id}'),
                  spec: m,
                  selected: m.id == scene.mode,
                  color: colour,
                  onTap: () => select(m.id),
                ),
          ],
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
        // The selected effect's sliders: the card grows and shrinks into
        // place and its content fades (another effect's content crossfades).
        _GrowUnlessReduced(
          reduced: reduced,
          child: AnimatedSwitcher(
            duration: reduced ? Duration.zero : Motion.medium,
            switchInCurve: Motion.emphasized,
            switchOutCurve: Motion.emphasized,
            // The card's size follows the incoming content at once; the
            // outgoing one fades on top.
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                for (final Widget p in previous)
                  Positioned(top: 0, left: 0, right: 0, child: p),
                ?current,
              ],
            ),
            child:
                current != null &&
                    (current.hasSpeed ||
                        current.hasFrequency ||
                        current.hasColorMode)
                ? Padding(
                    key: ValueKey<String>('mode-settings-${current.id}'),
                    padding: const EdgeInsets.only(top: Space.m),
                    child: GlassSurface(
                      padding: const EdgeInsets.all(Space.m),
                      child: _ModeSettings(
                        mode: current,
                        scene: scene,
                        whitePoints: whitePoints,
                        session: s,
                        fg: fg,
                      ),
                    ),
                  )
                : const SizedBox(
                    key: ValueKey<String>('no-mode-settings'),
                    width: double.infinity,
                  ),
          ),
        ),
      ],
    );
  }
}

/// Grows and shrinks [child]'s height into place (Motion.medium); under
/// Reduce Motion it just takes the new height (a zero-length AnimatedSize
/// would finish inside its own layout).
class _GrowUnlessReduced extends StatelessWidget {
  const _GrowUnlessReduced({required this.reduced, required this.child});
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) => reduced
      ? child
      : AnimatedSize(
          duration: Motion.medium,
          curve: Motion.emphasized,
          alignment: Alignment.topCenter,
          child: child,
        );
}

/// Columns and tile shape of the effects grid (the presets grid matches).
const int effectColumns = 3;
const double effectTileAspect = 0.95;

/// Solid Color, the everyday choice, as a full-width row above the effects.
class _SolidRow extends StatelessWidget {
  const _SolidRow({
    required this.spec,
    required this.selected,
    required this.color,
    required this.fg,
    required this.onTap,
    super.key,
  });

  final EbModeSpec spec;
  final bool selected;
  final Color color;
  final Color fg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Haptics h = HapticsScope.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: spec.name,
      hint: spec.description,
      // The same selection and press motion as the effect tiles.
      child: ChoiceFrame(
        selected: selected,
        onTap: () {
          h.play(HapticEvent.selection);
          onTap();
        },
        child: GlassSurface(
          radius: Radii.medium,
          liquid: true,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.m,
            vertical: Space.s,
          ),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 40,
                child: ModeGlyph(
                  glyph: spec.glyph,
                  color: color,
                  palette: <Color>[for (final int c in spec.gradient) Color(c)],
                  // Every effect moves, as the tiles do (paused off-screen,
                  // in the background and under Reduce Motion).
                  animate: true,
                ),
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Text(
                  spec.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(width: Space.s),
              // The colour it shows.
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(color: fg.withValues(alpha: 0.25)),
                ),
              ),
            ],
          ),
        ),
      ),
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
    // The label and value take the pill fill's fixed ink once the fill
    // reaches them.
    final Color onFill = PillFill.inkOf(dark: ToneScope.darkOf(context));
    Color ink(bool overFill) => overFill ? onFill : fg;
    const TextStyle figures = TextStyle(
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );
    Widget slider(String label, int value, void Function(int v) send) =>
        GlassSlider(
          value: value.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          semanticLabel: label,
          enabled: s != null,
          valueText: (double v) => l.levelOfTen(v.round()),
          leadingBuilder: (double v, double width) => Text(
            label,
            style: TextStyle(color: ink((v - 1) / 9 * width >= Space.m + 24)),
          ),
          trailingBuilder: (double v, double width) => Text(
            '${v.round()}',
            style: figures.copyWith(
              color: ink((v - 1) / 9 * width >= width - Space.m - 12),
            ),
          ),
          onChanged: (double v) => send(v.round()),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          mode.description,
          style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 13),
        ),
        if (mode.hasSpeed) ...<Widget>[
          const SizedBox(height: Space.s),
          slider(
            mode.speedLabel ?? l.speed,
            scene.speeds[mode.id - 1],
            (int v) => unawaited(s?.setSpeed(mode.id, v)),
          ),
        ],
        if (mode.hasFrequency) ...<Widget>[
          const SizedBox(height: Space.s),
          slider(
            mode.frequencyLabel ?? l.frequency,
            scene.frequencies[mode.id - 1],
            (int v) => unawaited(s?.setFrequency(mode.id, v)),
          ),
        ],
        if (kind != null) ...<Widget>[
          const SizedBox(height: Space.m),
          Text(l.colourSource, style: TextStyle(color: fg, fontSize: 13)),
          const SizedBox(height: Space.xs),
          Builder(
            builder: (BuildContext context) {
              final (String manual, String auto) = sourceLabels(
                kind,
                scene.layout,
                l,
              );
              return GlassSegmented<int>(
                segments: <(int, String)>[(0, manual), (1, auto)],
                selected: scene.colorMode(kind),
                onChanged: (int v) => unawaited(s?.setColorMode(kind, v)),
              );
            },
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
                      child: _BeaconSwatch(
                        label: slot == EbPoliceSlot.a ? l.beaconA : l.beaconB,
                        color: scene.police(slot),
                        whitePoints: whitePoints,
                        fg: fg,
                        onTap: s == null
                            ? null
                            : () => unawaited(
                                _pickBeacon(
                                  context,
                                  s,
                                  slot,
                                  scene.police(slot),
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

  /// Edits a beacon colour with this light's own colour surface.
  Future<void> _pickBeacon(
    BuildContext context,
    FixtureSession s,
    EbPoliceSlot slot,
    ChannelColor start,
  ) {
    final AppLocalizations l = AppLocalizations.of(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => ToneScope(
        tone: ToneScope.of(context),
        child: _BeaconSheet(
          title: slot == EbPoliceSlot.a ? l.beaconA : l.beaconB,
          start: start,
          whitePoints: whitePoints,
          // A beacon is a command (not a stream): send when a gesture ends.
          onChanged: (ChannelColor c) => unawaited(s.setPoliceColor(slot, c)),
        ),
      ),
    );
  }
}

class _BeaconSheet extends StatefulWidget {
  const _BeaconSheet({
    required this.title,
    required this.start,
    required this.whitePoints,
    required this.onChanged,
  });
  final String title;
  final ChannelColor start;
  final LedWhitePoints whitePoints;
  final ValueChanged<ChannelColor> onChanged;

  @override
  State<_BeaconSheet> createState() => _BeaconSheetState();
}

class _BeaconSheetState extends State<_BeaconSheet> {
  late ChannelColor _value = widget.start;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        0,
        Space.gutter,
        Space.gutter,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Space.m),
          ColourEditor(
            value: _value,
            whitePoints: widget.whitePoints,
            onChanged:
                (ChannelColor c, {required bool live, ColourIntent? intent}) {
                  setState(() => _value = c);
                  if (!live) widget.onChanged(c);
                },
          ),
        ],
      ),
    ),
  );
}

class _BeaconSwatch extends StatelessWidget {
  const _BeaconSwatch({
    required this.label,
    required this.color,
    required this.whitePoints,
    required this.fg,
    required this.onTap,
  });
  final String label;
  final ChannelColor color;
  final LedWhitePoints whitePoints;
  final Color fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: swatchOf(color, whitePoints),
              border: Border.all(color: fg.withValues(alpha: 0.3)),
            ),
          ),
          const SizedBox(width: Space.xs),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg),
            ),
          ),
        ],
      ),
    ),
  );
}
