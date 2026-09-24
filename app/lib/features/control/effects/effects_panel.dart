import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/color/led_white_points.dart';
import '../../../core/model/channel_color.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/protocol/eb/mode_catalog.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/controls/glass_slider.dart';
import '../../../design/glass/glass_surface.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';
import '../../../sessions/fixture_session.dart';
import '../colour/colour_editor.dart';
import 'mode_presentation.dart';

/// The effects this light has (only those its firmware supports, shown in
/// its own colours), the selected effect's sliders with the firmware's
/// labels, its colour source and the police beacons.
class EffectsPanel extends StatelessWidget {
  const EffectsPanel({
    required this.scene,
    required this.capabilities,
    required this.whitePoints,
    required this.session,
    required this.enabled,
    super.key,
  });

  final EbScene scene;
  final LightCapabilities capabilities;
  final LedWhitePoints whitePoints;
  final FixtureSession? session;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<EbModeSpec> modes = presentModes(capabilities, whitePoints, l);
    final EbModeSpec? current = modes
        .where((EbModeSpec m) => m.id == scene.mode)
        .firstOrNull;
    final Color colour = swatchOf(scene.color, whitePoints);
    final Color fg = ToneScope.of(context).dark
        ? Colors.white
        : const Color(0xFF15171C);
    final bool large = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final FixtureSession? s = enabled ? session : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GridView.count(
          crossAxisCount: large ? 2 : 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: Space.s,
          crossAxisSpacing: Space.s,
          childAspectRatio: 0.95,
          children: <Widget>[
            for (final EbModeSpec m in modes)
              ModeTile(
                key: ValueKey<String>('mode-${m.id}'),
                spec: m,
                selected: m.id == scene.mode,
                color: colour,
                onTap: () {
                  if (s != null) unawaited(s.setMode(m.id));
                },
              ),
          ],
        ),
        if (capabilities.layout == ChannelLayout.w &&
            !capabilities.supportsMode(10))
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Text(
              l.modeUnavailableRainbow,
              style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 13),
            ),
          ),
        if (current != null &&
            (current.hasSpeed ||
                current.hasFrequency ||
                current.hasColorMode)) ...<Widget>[
          const SizedBox(height: Space.m),
          GlassSurface(
            padding: const EdgeInsets.all(Space.m),
            child: _ModeSettings(
              mode: current,
              scene: scene,
              whitePoints: whitePoints,
              session: s,
              fg: fg,
            ),
          ),
        ],
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
    Widget slider(String label, int value, void Function(int v) send) =>
        GlassSlider(
          value: value.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          semanticLabel: label,
          enabled: s != null,
          valueText: (double v) => l.levelOfTen(v.round()),
          leading: Text(label, style: TextStyle(color: fg)),
          trailing: Text(
            '$value',
            style: TextStyle(
              color: fg,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
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
            onChanged: (ChannelColor c, {required bool live}) {
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
