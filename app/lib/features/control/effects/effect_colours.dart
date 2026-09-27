import 'package:flutter/material.dart';

import '../../../core/color/colour_engine.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/model/channel_color.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';
import '../colour/colour_editor.dart';
import 'mode_presentation.dart';

/// "Colour source" for effects of [kind] (Fireworks, Club, Police): the
/// picked colours (0) or the effect's own (1), in [layout]'s words. With
/// [selected] null (lights differ) no choice is shown as selected.
class ColourSourceControl extends StatelessWidget {
  const ColourSourceControl({
    required this.kind,
    required this.layout,
    required this.selected,
    required this.fg,
    required this.onChanged,
    super.key,
  });

  final EbColorModeKind kind;
  final ChannelLayout layout;
  final int? selected;
  final Color fg;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final (String manual, String auto) = sourceLabels(kind, layout, l);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l.colourSource, style: TextStyle(color: fg, fontSize: 13)),
        const SizedBox(height: Space.xs),
        GlassSegmented<int?>(
          segments: <(int?, String)>[(0, manual), (1, auto)],
          selected: selected,
          onChanged: (int? v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

/// A police beacon: its colour and name, tapped to edit. [color] null: the
/// lights differ (a split swatch).
class BeaconSwatch extends StatelessWidget {
  const BeaconSwatch({
    required this.label,
    required this.color,
    required this.fg,
    required this.onTap,
    super.key,
  });
  final String label;
  final Color? color;
  final Color fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color? c = color;
    final Border border = Border.all(color: fg.withValues(alpha: 0.3));
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: c != null
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      color: c,
                      border: border,
                    )
                  : BoxDecoration(
                      shape: BoxShape.circle,
                      border: border,
                      // Mixed: half and half.
                      gradient: LinearGradient(
                        colors: <Color>[
                          fg.withValues(alpha: 0.12),
                          fg.withValues(alpha: 0.12),
                          fg.withValues(alpha: 0.45),
                          fg.withValues(alpha: 0.45),
                        ],
                        stops: const <double>[0, 0.5, 0.5, 1],
                      ),
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
}

/// Edits a beacon colour from [start] with the colour surface of its
/// layout. A beacon is a command (not a stream): [onChanged] is called when
/// a gesture ends.
Future<void> showBeaconSheet(
  BuildContext context, {
  required String title,
  required ChannelColor start,
  required LedWhitePoints whitePoints,
  required void Function(ChannelColor color, ColourIntent? intent) onChanged,
  bool showChannels = true,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext ctx) => ToneScope(
    tone: ToneScope.of(context),
    child: _BeaconSheet(
      title: title,
      start: start,
      whitePoints: whitePoints,
      showChannels: showChannels,
      onChanged: onChanged,
    ),
  ),
);

class _BeaconSheet extends StatefulWidget {
  const _BeaconSheet({
    required this.title,
    required this.start,
    required this.whitePoints,
    required this.showChannels,
    required this.onChanged,
  });
  final String title;
  final ChannelColor start;
  final LedWhitePoints whitePoints;
  final bool showChannels;
  final void Function(ChannelColor color, ColourIntent? intent) onChanged;

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
            showChannels: widget.showChannels,
            onChanged:
                (ChannelColor c, {required bool live, ColourIntent? intent}) {
                  setState(() => _value = c);
                  if (!live) widget.onChanged(c, intent);
                },
          ),
        ],
      ),
    ),
  );
}
