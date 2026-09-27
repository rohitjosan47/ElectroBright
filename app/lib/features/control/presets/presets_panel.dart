import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/color/colour_engine.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/haptics/haptics.dart';
import '../../../design/haptics/haptics_scope.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../drivers/electrobright/eb_session.dart';
import '../../../drivers/electrobright/eb_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../sessions/fixture_session.dart';
import '../colour/colour_editor.dart';
import '../effects/mode_presentation.dart';
import 'preset_meta.dart';
import 'preset_slots.dart';

/// The light's preset slots: tap to load, tap an empty slot to save the
/// current look, long-press for rename / overwrite / clear. Previews use the
/// light's own colours (a single-white light shows its output).
class PresetsPanel extends ConsumerWidget {
  const PresetsPanel({
    required this.fixtureId,
    required this.scene,
    required this.onLight,
    required this.capabilities,
    required this.whitePoints,
    required this.session,
    required this.enabled,
    super.key,
  });

  final String fixtureId;
  final EbScene scene;

  /// Slots that hold a preset on the light.
  final Set<int> onLight;
  final LightCapabilities capabilities;
  final LedWhitePoints whitePoints;
  final FixtureSession? session;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final PresetMeta meta = ref.watch(presetMetaProvider(fixtureId));
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    final int? active = meta.activeSlot(scene, onLight);
    final int? from = meta.lastLoaded;
    final String? status = active != null
        ? '${l.presetActive}: ${_name(l, meta, active)}'
        : from != null && onLight.contains(from)
        ? l.presetModifiedFrom(_name(l, meta, from))
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s, left: Space.xxs),
            child: Text(
              status,
              key: const ValueKey<String>('preset-status'),
              style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 13),
            ),
          ),
        PresetSlotGrid(
          slots: <Widget>[
            for (int slot = 0; slot < capabilities.presetSlots; slot++)
              _slotTile(
                l,
                meta,
                slot,
                active: slot == active,
                fg: fg,
                context: context,
                ref: ref,
              ),
          ],
        ),
      ],
    );
  }

  Widget _slotTile(
    AppLocalizations l,
    PresetMeta meta,
    int slot, {
    required bool active,
    required Color fg,
    required BuildContext context,
    required WidgetRef ref,
  }) {
    final ChannelLayout layout = capabilities.layout;
    final EbScene? preview = meta[slot]?.scene;
    final EbScene? p = preview?.layout == layout ? preview : null;
    return PresetSlotTile(
      key: ValueKey<String>('preset-$slot'),
      slot: slot,
      filled: onLight.contains(slot),
      active: active,
      name: _name(l, meta, slot),
      colours: <Color>[if (p != null) swatchOf(p.color, whitePoints)],
      detail: p == null
          ? null
          : '${presentMode(EbModeCatalog.byId(p.mode), layout, whitePoints, l).name}'
                ' · ${_level(p)} %',
      fg: fg,
      onTap: !enabled
          ? null
          : () => onLight.contains(slot)
                ? _load(context, ref, slot)
                : _save(context, ref, slot, ask: true),
      onLongPress: !enabled || !onLight.contains(slot)
          ? null
          : () => _menu(context, ref, slot),
    );
  }

  /// Brightness, or on a single-white light the real output.
  static int _level(EbScene s) => s.layout == ChannelLayout.w
      ? (ColourEngine.output(s.color[0], s.brightness) * 100).round()
      : (s.brightness / 255 * 100).round();

  // A light on firmware before 3.6.0 may still hold presets from the old
  // format; they show as 'Preset N' without a preview until the light is
  // updated to 3.6.0, which clears them.
  static String _name(AppLocalizations l, PresetMeta meta, int slot) =>
      meta[slot]?.name ?? l.presetDefaultName(slot + 1);

  PresetMetaNotifier _meta(WidgetRef ref) =>
      ref.read(presetMetaProvider(fixtureId).notifier);

  /// True when the light loaded it (the tile then pulses).
  Future<bool> _load(BuildContext context, WidgetRef ref, int slot) async {
    final FixtureSession? s = session;
    if (s == null) return false;
    final EbPresetResult r = await s.presetLoad(slot);
    if (!context.mounted) return false;
    if (r.result.isSuccess) {
      _meta(ref).loaded(slot, r.scene);
      HapticsScope.of(context).play(HapticEvent.presetLoaded);
      showGlassToast(
        context,
        AppLocalizations.of(context).presetLoaded,
        icon: Icons.check_circle_rounded,
      );
      return true;
    }
    _failed(context, r.result);
    return false;
  }

  /// True when the light stored it (the tile then pulses).
  Future<bool> _save(
    BuildContext context,
    WidgetRef ref,
    int slot, {
    required bool ask,
  }) async {
    final FixtureSession? s = session;
    if (s == null) return false;
    String? name;
    if (ask) {
      name = await askPresetName(context, null);
      if (name == null || !context.mounted) return false;
    }
    final EbPresetResult r = await s.presetSave(slot);
    if (!context.mounted) return false;
    if (r.result.isSuccess) {
      _meta(ref).saved(slot, r.scene ?? scene, name: name);
      HapticsScope.of(context).play(HapticEvent.success);
      showGlassToast(
        context,
        AppLocalizations.of(context).presetSaved,
        icon: Icons.check_circle_rounded,
      );
      return true;
    }
    _failed(context, r.result);
    return false;
  }

  /// True when a load or overwrite from the menu succeeded.
  Future<bool> _menu(BuildContext context, WidgetRef ref, int slot) async {
    final PresetAction? action = await showPresetMenu(context);
    if (!context.mounted || action == null) return false;
    switch (action) {
      case PresetAction.load:
        return _load(context, ref, slot);
      case PresetAction.rename:
        final PresetMeta meta = ref.read(presetMetaProvider(fixtureId));
        final String? name = await askPresetName(context, meta[slot]?.name);
        if (name != null) _meta(ref).rename(slot, name);
      case PresetAction.overwrite:
        return _save(context, ref, slot, ask: false);
      case PresetAction.clear:
        final EbResult r = await session!.presetDelete(slot);
        if (!context.mounted) return false;
        if (r.isSuccess) {
          _meta(ref).clear(slot);
        } else {
          _failed(context, r);
        }
    }
    return false;
  }

  void _failed(BuildContext context, EbResult r) {
    final AppLocalizations l = AppLocalizations.of(context);
    HapticsScope.of(context).play(HapticEvent.error);
    showGlassToast(context, switch (r.outcome) {
      EbOutcome.disconnected => l.errorOffline,
      _ when r.code == 'STORAGE' => l.errorStorage,
      _ => l.errorGeneric,
    }, icon: Icons.error_outline_rounded);
  }
}
