import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/color/led_white_points.dart';
import '../../core/model/fixture.dart';
import '../../design/components/glass_controls.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/group_presets.dart';
import '../../sessions/group_session.dart';
import '../control/colour/colour_editor.dart';
import '../control/presets/preset_slots.dart';
import 'group_screen.dart';

/// The group's preset slots, kept on this phone: tap an empty slot to save
/// the lights' current looks, a filled one to apply it; long-press for
/// load / rename / overwrite / clear. The last applied slot is marked until
/// the next group command.
class GroupPresetsTab extends ConsumerWidget {
  const GroupPresetsTab({
    required this.group,
    required this.enabled,
    required this.run,
    super.key,
  });
  final GroupSession group;
  final bool enabled;
  final GroupRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final ({List<GroupPreset?> presets, int? active}) st = ref.watch(
      groupStatusProvider(
        group.kind,
      ).select((GroupStatus s) => (presets: s.presets, active: s.activePreset)),
    );
    // The lights' white points, for the previews (fixtures change rarely).
    final Map<String, LedWhitePoints> whitePoints = ref.watch(
      fixturesProvider.select(
        (List<Fixture> all) => <String, LedWhitePoints>{
          for (final Fixture f in all) f.id: f.whitePoints,
        },
      ),
    );
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    final int? active = st.active;
    final GroupPreset? current = active == null ? null : st.presets[active];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s, left: Space.xxs),
            child: Text(
              '${l.presetActive}: ${current.name}',
              key: const ValueKey<String>('preset-status'),
              style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 13),
            ),
          ),
        PresetSlotGrid(
          slots: <Widget>[
            for (int slot = 0; slot < GroupPresets.slots; slot++)
              PresetSlotTile(
                key: ValueKey<String>('group-preset-$slot'),
                slot: slot,
                filled: st.presets[slot] != null,
                active: slot == active,
                name: st.presets[slot]?.name ?? l.presetEmpty,
                colours: _colours(st.presets[slot], whitePoints),
                detail: switch (st.presets[slot]) {
                  final GroupPreset p => l.groupPresetLights(p.lights.length),
                  null => null,
                },
                fg: fg,
                onTap: !enabled
                    ? null
                    : () => st.presets[slot] != null
                          ? _apply(context, slot)
                          : _save(context, slot, name: null),
                onLongPress: !enabled || st.presets[slot] == null
                    ? null
                    : () => _menu(context, slot, st.presets[slot]!),
              ),
          ],
        ),
      ],
    );
  }

  /// Up to four different colours of the preset's lights, in its order.
  static List<Color> _colours(
    GroupPreset? p,
    Map<String, LedWhitePoints> whitePoints,
  ) {
    if (p == null) return const <Color>[];
    final List<Color> out = <Color>[];
    for (final MapEntry<String, GroupPresetLight> e in p.lights.entries) {
      final Color c = swatchOf(
        e.value.colour,
        whitePoints[e.key] ?? const LedWhitePoints(),
      );
      if (!out.contains(c)) out.add(c);
      if (out.length == PresetSlotTile.maxColours) break;
    }
    return out;
  }

  /// True when some light took it (the tile then pulses).
  Future<bool> _apply(BuildContext context, int slot) async {
    final Future<GroupResult> sent = group.applyPreset(slot);
    run(sent);
    final GroupResult r = await sent;
    if (!context.mounted || r.ok == 0) return false;
    HapticsScope.of(context).play(HapticEvent.presetLoaded);
    return true;
  }

  /// Saves the lights' looks: asks for a name when [name] is null. True
  /// when something was saved.
  Future<bool> _save(
    BuildContext context,
    int slot, {
    required String? name,
  }) async {
    final String? n = name ?? await askPresetName(context, null);
    if (n == null || !context.mounted) return false;
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupSaveResult r = group.savePreset(slot, n);
    if (r.saved == 0) {
      HapticsScope.of(context).play(HapticEvent.error);
      showGlassToast(
        context,
        l.groupPresetNothing,
        icon: Icons.error_outline_rounded,
      );
      return false;
    }
    HapticsScope.of(context).play(HapticEvent.success);
    showGlassToast(
      context,
      r.saved < r.total
          ? l.groupPresetSavedSome(r.saved, r.total)
          : l.presetSaved,
      icon: Icons.check_circle_rounded,
    );
    return true;
  }

  /// True when an apply or overwrite from the menu succeeded.
  Future<bool> _menu(BuildContext context, int slot, GroupPreset p) async {
    final PresetAction? action = await showPresetMenu(context);
    if (!context.mounted || action == null) return false;
    switch (action) {
      case PresetAction.load:
        return _apply(context, slot);
      case PresetAction.rename:
        final String? name = await askPresetName(context, p.name);
        if (name != null) group.renamePreset(slot, name);
      case PresetAction.overwrite:
        return _save(context, slot, name: p.name);
      case PresetAction.clear:
        group.deletePreset(slot);
    }
    return false;
  }
}
