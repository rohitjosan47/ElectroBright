import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/color/light_surfaces.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/components/name_dialog.dart';
import '../../../design/glass/glass_surface.dart';
import '../../../design/haptics/haptics.dart';
import '../../../design/haptics/haptics_scope.dart';
import '../../../design/tokens/tokens.dart';
import '../../../l10n/app_localizations.dart';
import '../effects/effects_grid.dart';

/// Preset slots in a grid shaped like the effect tiles (15 slots: 3 × 5;
/// two columns at large text).
class PresetSlotGrid extends StatelessWidget {
  const PresetSlotGrid({required this.slots, super.key});
  final List<Widget> slots;

  @override
  Widget build(BuildContext context) {
    final bool large = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return GridView.count(
      crossAxisCount: large ? 2 : effectColumns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: Space.s,
      crossAxisSpacing: Space.s,
      childAspectRatio: large ? 1.2 : effectTileAspect,
      children: slots,
    );
  }
}

/// One preset slot: the same selection and press motion as the effect
/// tiles, and a success pulse when a load or save through it succeeds (an
/// empty slot only presses; a save that fills it pulses).
class PresetSlotTile extends StatefulWidget {
  const PresetSlotTile({
    required this.slot,
    required this.filled,
    required this.active,
    required this.name,
    required this.colours,
    required this.fg,
    required this.onTap,
    required this.onLongPress,
    this.detail,
    super.key,
  });

  final int slot;
  final bool filled;
  final bool active;
  final String name;

  /// The preview: one colour as a dot, several (up to 4 shown) as a small
  /// cluster; none as a neutral dot.
  final List<Color> colours;

  /// A line under the name (e.g. the effect and level).
  final String? detail;
  final Color fg;

  /// Each returns true when it was carried out (the tile then pulses).
  final Future<bool> Function()? onTap;
  final Future<bool> Function()? onLongPress;

  static const int maxColours = 4;

  @override
  State<PresetSlotTile> createState() => _PresetSlotTileState();
}

class _PresetSlotTileState extends State<PresetSlotTile> {
  int _pulse = 0;

  VoidCallback? _run(Future<bool> Function()? action) => action == null
      ? null
      : () => unawaited(
          action().then((bool ok) {
            if (ok && mounted) setState(() => _pulse++);
          }),
        );

  Widget _dot(Color colour, {double size = 22, Widget? child}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
    child: child,
  );

  Widget _preview() {
    final List<Color> colours = widget.colours;
    final Color fg = widget.fg;
    if (colours.length <= 1) {
      return _dot(
        colours.firstOrNull ?? fg.withValues(alpha: 0.12),
        child: widget.filled
            ? null
            : Icon(Icons.add_rounded, size: 16, color: fg),
      );
    }
    const double size = 16, step = 10;
    final int n = colours.length.clamp(0, PresetSlotTile.maxColours);
    return SizedBox(
      width: size + (n - 1) * step,
      height: 22,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[
          for (int i = 0; i < n; i++)
            Positioned(
              left: i * step,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colours[i],
                  border: Border.all(color: fg.withValues(alpha: 0.18)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool filled = widget.filled;
    final String name = widget.name;
    final Color fg = widget.fg;
    final String? detail = widget.detail;
    return Semantics(
      button: true,
      selected: widget.active,
      label: filled ? name : '${l.presetEmpty}, ${l.presetSave}',
      value: detail,
      child: ChoiceFrame(
        selected: widget.active,
        pulse: _pulse,
        onTap: _run(widget.onTap),
        onLongPress: _run(widget.onLongPress),
        child: GlassSurface(
          radius: Radii.medium,
          liquid: true,
          quietGlint: true,
          padding: const EdgeInsets.all(Space.s),
          child: Opacity(
            opacity: filled
                ? 1
                : LightSurfaces.dim(0.55, dark: fg == Colors.white),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _preview(),
                    const Spacer(),
                    Text(
                      '${widget.slot + 1}',
                      style: TextStyle(
                        color: fg.withValues(
                          alpha: LightSurfaces.dim(
                            0.5,
                            dark: fg == Colors.white,
                          ),
                        ),
                        fontSize: 12,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  filled ? name : l.presetEmpty,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                if (filled && detail != null)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg.withValues(
                        alpha: LightSurfaces.dim(0.6, dark: fg == Colors.white),
                      ),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the long-press menu of a filled slot chose.
enum PresetAction { load, rename, overwrite, clear }

/// The long-press menu of a filled slot (null = dismissed).
Future<PresetAction?> showPresetMenu(BuildContext context) {
  final AppLocalizations l = AppLocalizations.of(context);
  HapticsScope.of(context).play(HapticEvent.longPress);
  return showModalBottomSheet<PresetAction>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.play_arrow_rounded),
            title: Text(l.presetLoad),
            onTap: () => Navigator.pop(ctx, PresetAction.load),
          ),
          ListTile(
            leading: const Icon(Icons.edit_rounded),
            title: Text(l.rename),
            onTap: () => Navigator.pop(ctx, PresetAction.rename),
          ),
          ListTile(
            leading: const Icon(Icons.save_rounded),
            title: Text(l.presetOverwrite),
            onTap: () => Navigator.pop(ctx, PresetAction.overwrite),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(l.presetClear),
            onTap: () => Navigator.pop(ctx, PresetAction.clear),
          ),
        ],
      ),
    ),
  );
}

/// Name for a preset (null = cancelled), with suggestions.
Future<String?> askPresetName(BuildContext context, String? current) {
  final AppLocalizations l = AppLocalizations.of(context);
  return showNameDialog(
    context,
    title: l.presetName,
    current: current,
    suggestions: <String>[
      l.presetSuggestCozy,
      l.presetSuggestCinema,
      l.presetSuggestFocus,
      l.presetSuggestParty,
    ],
  );
}
