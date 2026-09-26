import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/color/colour_engine.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_surfaces.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/components/name_dialog.dart';
import '../../../design/glass/glass_surface.dart';
import '../../../design/haptics/haptics.dart';
import '../../../design/haptics/haptics_scope.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../drivers/electrobright/eb_session.dart';
import '../../../drivers/electrobright/eb_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../sessions/fixture_session.dart';
import '../colour/colour_editor.dart';
import '../effects/effects_panel.dart';
import '../effects/mode_presentation.dart';
import 'preset_meta.dart';

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
    final bool large = MediaQuery.textScalerOf(context).scale(1) > 1.5;
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
        GridView.count(
          // 15 slots: 3 × 5, shaped like the effect tiles.
          crossAxisCount: large ? 2 : effectColumns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: Space.s,
          crossAxisSpacing: Space.s,
          childAspectRatio: large ? 1.2 : effectTileAspect,
          children: <Widget>[
            for (int slot = 0; slot < capabilities.presetSlots; slot++)
              _SlotTile(
                key: ValueKey<String>('preset-$slot'),
                slot: slot,
                filled: onLight.contains(slot),
                active: slot == active,
                name: _name(l, meta, slot),
                preview: meta[slot]?.scene,
                layout: capabilities.layout,
                whitePoints: whitePoints,
                fg: fg,
                onTap: !enabled
                    ? null
                    : () => onLight.contains(slot)
                          ? _load(context, ref, slot)
                          : _save(context, ref, slot, ask: true),
                onLongPress: !enabled || !onLight.contains(slot)
                    ? null
                    : () => _menu(context, ref, slot),
              ),
          ],
        ),
      ],
    );
  }

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
      name = await _askName(context, null);
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
    final AppLocalizations l = AppLocalizations.of(context);
    HapticsScope.of(context).play(HapticEvent.longPress);
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text(l.presetLoad),
              onTap: () => Navigator.pop(ctx, 'load'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: Text(l.rename),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.save_rounded),
              title: Text(l.presetOverwrite),
              onTap: () => Navigator.pop(ctx, 'overwrite'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(l.presetClear),
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return false;
    switch (action) {
      case 'load':
        return _load(context, ref, slot);
      case 'rename':
        final PresetMeta meta = ref.read(presetMetaProvider(fixtureId));
        final String? name = await _askName(context, meta[slot]?.name);
        if (name != null) _meta(ref).rename(slot, name);
      case 'overwrite':
        return _save(context, ref, slot, ask: false);
      case 'clear':
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

  /// Name for a preset (null = cancelled), with suggestions.
  static Future<String?> _askName(BuildContext context, String? current) {
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
}

/// One preset slot: the same selection and press motion as the effect
/// tiles, and a success pulse when a load or save through it succeeds (an
/// empty slot only presses; a save that fills it pulses).
class _SlotTile extends StatefulWidget {
  const _SlotTile({
    required this.slot,
    required this.filled,
    required this.active,
    required this.name,
    required this.preview,
    required this.layout,
    required this.whitePoints,
    required this.fg,
    required this.onTap,
    required this.onLongPress,
    super.key,
  });

  final int slot;
  final bool filled;
  final bool active;
  final String name;
  final EbScene? preview;
  final ChannelLayout layout;
  final LedWhitePoints whitePoints;
  final Color fg;

  /// Each returns true when the light carried it out.
  final Future<bool> Function()? onTap;
  final Future<bool> Function()? onLongPress;

  @override
  State<_SlotTile> createState() => _SlotTileState();
}

class _SlotTileState extends State<_SlotTile> {
  int _pulse = 0;

  VoidCallback? _run(Future<bool> Function()? action) => action == null
      ? null
      : () => unawaited(
          action().then((bool ok) {
            if (ok && mounted) setState(() => _pulse++);
          }),
        );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final int slot = widget.slot;
    final bool filled = widget.filled;
    final String name = widget.name;
    final ChannelLayout layout = widget.layout;
    final LedWhitePoints whitePoints = widget.whitePoints;
    final Color fg = widget.fg;
    final EbScene? preview = widget.preview;
    final EbScene? p = preview?.layout == layout ? preview : null;
    final String? detail = p == null
        ? null
        : '${presentMode(EbModeCatalog.byId(p.mode), layout, whitePoints, l).name}'
              ' · ${_level(p)} %';
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
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p != null
                            ? swatchOf(p.color, whitePoints)
                            : fg.withValues(alpha: 0.12),
                      ),
                      child: filled
                          ? null
                          : Icon(Icons.add_rounded, size: 16, color: fg),
                    ),
                    const Spacer(),
                    Text(
                      '${slot + 1}',
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

  /// Brightness, or on a single-white light the real output.
  int _level(EbScene s) => s.layout == ChannelLayout.w
      ? (ColourEngine.output(s.color[0], s.brightness) * 100).round()
      : (s.brightness / 255 * 100).round();
}
