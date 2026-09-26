import 'package:flutter/material.dart';

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

/// Solid Color as a row of its own, the other [modes] in a grid; [selected]
/// is lit. [badges]: a short note on a tile (e.g. "3/5": how many of the
/// lights have that effect).
class EffectsGrid extends StatelessWidget {
  const EffectsGrid({
    required this.modes,
    required this.selected,
    required this.color,
    required this.animate,
    required this.onSelect,
    this.badges = const <int, String>{},
    super.key,
  });

  final List<EbModeSpec> modes;
  final int? selected;

  /// The colour the effects are drawn in.
  final Color color;

  /// The effects move only while the light is on and connected; otherwise
  /// they show their still frames.
  final bool animate;
  final ValueChanged<int> onSelect;
  final Map<int, String> badges;

  @override
  Widget build(BuildContext context) {
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    final bool large = MediaQuery.textScalerOf(context).scale(1) > 1.5;
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
            selected: selected == solid.id,
            color: color,
            fg: fg,
            animate: animate,
            onTap: () => onSelect(solid.id),
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
                  selected: m.id == selected,
                  color: color,
                  animate: animate,
                  badge: badges[m.id],
                  onTap: () => onSelect(m.id),
                ),
          ],
        ),
      ],
    );
  }
}

/// The selected effect's settings card ([builder]'s content; none while
/// [mode] is null): it grows and shrinks into place and its content fades
/// (another effect's content crossfades).
class ModeSettingsSwitcher extends StatelessWidget {
  const ModeSettingsSwitcher({
    required this.mode,
    required this.builder,
    super.key,
  });

  final EbModeSpec? mode;
  final Widget Function(EbModeSpec mode) builder;

  @override
  Widget build(BuildContext context) {
    final bool reduced = Motion.reduced(context);
    final EbModeSpec? current = mode;
    return _GrowUnlessReduced(
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
        child: current != null
            ? Padding(
                key: ValueKey<String>('mode-settings-${current.id}'),
                padding: const EdgeInsets.only(top: Space.m),
                child: GlassSurface(
                  padding: const EdgeInsets.all(Space.m),
                  child: builder(current),
                ),
              )
            : const SizedBox(
                key: ValueKey<String>('no-mode-settings'),
                width: double.infinity,
              ),
      ),
    );
  }
}

/// An effect's description and its speed and frequency sliders (1..10, with
/// the firmware's labels).
class ModeSliders extends StatelessWidget {
  const ModeSliders({
    required this.mode,
    required this.speed,
    required this.frequency,
    required this.enabled,
    required this.fg,
    required this.onSpeed,
    required this.onFrequency,
    super.key,
  });

  final EbModeSpec mode;
  final int speed;
  final int frequency;
  final bool enabled;
  final Color fg;
  final ValueChanged<int> onSpeed;
  final ValueChanged<int> onFrequency;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    // The label and value take the pill fill's fixed ink once the fill
    // reaches them.
    final Color onFill = PillFill.inkOf(dark: ToneScope.darkOf(context));
    Color ink(bool overFill) => overFill ? onFill : fg;
    const TextStyle figures = TextStyle(
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );
    Widget slider(String label, int value, ValueChanged<int> send) =>
        GlassSlider(
          value: value.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          semanticLabel: label,
          enabled: enabled,
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
          slider(mode.speedLabel ?? l.speed, speed, onSpeed),
        ],
        if (mode.hasFrequency) ...<Widget>[
          const SizedBox(height: Space.s),
          slider(mode.frequencyLabel ?? l.frequency, frequency, onFrequency),
        ],
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
    required this.animate,
    required this.onTap,
    super.key,
  });

  final EbModeSpec spec;
  final bool selected;
  final Color color;
  final Color fg;
  final bool animate;
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
                  // As the tiles do (paused off-screen, in the background,
                  // under Reduce Motion and while the light is off).
                  animate: animate,
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
