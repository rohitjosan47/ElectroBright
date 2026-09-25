import 'package:flutter/material.dart';

import '../../../core/color/color_science.dart';
import '../../../core/color/colour_engine.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_tone.dart';
import '../../../core/color/steady_colour.dart';
import '../../../core/model/channel_color.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../design/components/fixture_type.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/controls/glass_slider.dart';
import '../../../design/controls/hue_wheel.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/screen_colour.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';

/// Called with the new colour; [live] while a finger is still dragging.
/// [intent]: what the user picked, before 8-bit encoding (the editor always
/// passes it).
typedef ColourChanged = void Function(
  ChannelColor color, {
  required bool live,
  ColourIntent? intent,
});

/// Picks a colour the way this light can make it: a level (single white),
/// warm-to-cool temperature (tunable white), the colour wheel (RGB), the
/// wheel plus the white LED (RGBW), or wheel / tunable white (RGBCCT) —
/// plus exact channel values. The last intent is kept, so a light echoing a
/// rounded value never moves the controls (and hue survives greys).
class ColourEditor extends StatefulWidget {
  const ColourEditor({
    required this.value,
    required this.onChanged,
    this.whitePoints = const LedWhitePoints(),
    this.onGestureStart,
    this.onGestureEnd,
    this.showChannels = true,
    this.enabled = true,
    super.key,
  });

  final ChannelColor value;
  final ColourChanged onChanged;
  final LedWhitePoints whitePoints;
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  final bool showChannels;
  final bool enabled;

  @override
  State<ColourEditor> createState() => _ColourEditorState();
}

enum _Sub { colour, white, custom }

/// The last intent and what it encodes to.
typedef _Model = ({ColourIntent intent, ChannelColor encoded});

class _ColourEditorState extends State<ColourEditor> {
  late ColourEngine _engine;

  /// Live changes go here only: the controls that show the colour listen to
  /// it, the rest of the editor is rebuilt when a gesture ends.
  late final ValueNotifier<_Model> _model;

  /// The editor's tree as last built. A parent rebuilding with the colour
  /// the editor itself just sent (every live frame) gets it back unchanged.
  Widget? _tree;

  ColourIntent get _intent => _model.value.intent;
  ChannelColor get _encoded => _model.value.encoded;
  ChannelLayout get _layout => widget.value.layout;

  @override
  void initState() {
    super.initState();
    _engine = ColourEngine(widget.whitePoints);
    _model = ValueNotifier<_Model>((
      intent: _engine.decode(widget.value),
      encoded: widget.value,
    ));
  }

  @override
  void didUpdateWidget(ColourEditor old) {
    super.didUpdateWidget(old);
    if (widget.whitePoints != old.whitePoints) {
      _engine = ColourEngine(widget.whitePoints);
      _tree = null;
    }
    if (widget.enabled != old.enabled ||
        widget.showChannels != old.showChannels) {
      _tree = null;
    }
    if (widget.value != _encoded) {
      _model.value = (
        intent: _engine.decode(widget.value, hint: _intent),
        encoded: widget.value,
      );
      _tree = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tree = null;
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  void _apply(ColourIntent i, {required bool live}) {
    final ChannelColor c = _engine.encode(i, _layout);
    _model.value = (intent: i, encoded: c);
    if (!live) _rebuild();
    widget.onChanged(c, live: live, intent: i);
  }

  void _rebuild() => setState(() => _tree = null);

  void _start() => widget.onGestureStart?.call();

  void _end() {
    widget.onChanged(_encoded, live: false, intent: _intent);
    widget.onGestureEnd?.call();
    _rebuild();
  }

  /// [builder] with the current intent and colour, rebuilt on live changes.
  Widget _live(Widget Function(ColourIntent intent, ChannelColor encoded) b) =>
      ValueListenableBuilder<_Model>(
        valueListenable: _model,
        builder: (BuildContext context, _Model m, _) => b(m.intent, m.encoded),
      );

  _Sub get _sub => switch (_intent) {
    WhiteIntent() => _Sub.white,
    RawIntent() => _Sub.custom,
    HsvIntent() => _Sub.colour,
  };

  @override
  Widget build(BuildContext context) => _tree ??= _build(context);

  Widget _build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final ColourSurface surface = LightCapabilities.assumed(_layout)
        .colourSurface;
    final List<Widget> children = switch (surface) {
      ColourSurface.intensity => <Widget>[_levelSlider(l)],
      ColourSurface.tunableWhite => <Widget>[_kelvinPanel(l)],
      ColourSurface.colour => <Widget>[_wheel()],
      ColourSurface.colourPlusWhite => <Widget>[
        _wheel(),
        const SizedBox(height: Space.m),
        _whiteLedSlider(l),
      ],
      ColourSurface.colourPlusTunableWhite => <Widget>[
        GlassSegmented<_Sub>(
          segments: <(_Sub, String)>[
            (_Sub.colour, l.tabColour),
            (_Sub.white, l.tabWhite),
            if (_sub == _Sub.custom) (_Sub.custom, l.tabCustom),
          ],
          selected: _sub,
          elevated: false,
          onChanged: (_Sub s) {
            // Switching is explicit: the other side goes to zero.
            if (s == _Sub.white) {
              _apply(const WhiteIntent(4000, 1), live: false);
            } else if (s == _Sub.colour) {
              _apply(const HsvIntent(Hsv(30, 1, 1)), live: false);
            }
          },
        ),
        const SizedBox(height: Space.m),
        if (_sub == _Sub.white) _kelvinPanel(l) else _wheel(),
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...children,
        if (widget.showChannels &&
            surface != ColourSurface.intensity) ...<Widget>[
          const SizedBox(height: Space.m),
          _live(
            (_, ChannelColor encoded) => _Channels(
              value: encoded,
              whitePoints: widget.whitePoints,
              enabled: widget.enabled,
              onStart: _start,
              onEnd: _end,
              onChanged: (
                ChannelColor c, {
                required bool live,
                ColourIntent? intent,
              }) => _apply(RawIntent(c), live: live),
            ),
          ),
        ],
      ],
    );
  }

  static Hsv _hsvOf(ColourIntent intent, ChannelColor encoded) =>
      switch (intent) {
        HsvIntent(:final Hsv hsv) => hsv,
        _ => Hsv.fromRgb8(encoded[0], encoded[1], encoded[2]),
      };

  Widget _wheel() => _live((ColourIntent intent, ChannelColor encoded) {
    final double white = switch (intent) {
      HsvIntent(:final double white) => white,
      _ => 0,
    };
    return HueWheel(
      value: _hsvOf(intent, encoded),
      enabled: widget.enabled,
      onChangeStart: _start,
      onChanged: (Hsv v) => _apply(HsvIntent(v, white: white), live: true),
      onChangeEnd: (_) => _end(),
    );
  });

  Widget _whiteLedSlider(AppLocalizations l) =>
      _live((ColourIntent intent, ChannelColor encoded) {
        final Hsv hsv = _hsvOf(intent, encoded);
        final double white = encoded.role(ChannelRole.w) / 255;
        final Color led = ledColor(ChannelRole.w, widget.whitePoints);
        return _Labelled(
          label: l.whiteLed,
          value: '${(white * 100).round()} %',
          child: GlassSlider(
            elevated: false,
            value: white,
            semanticLabel: l.whiteLed,
            enabled: widget.enabled,
            track: <Color>[const Color(0xFF3A3A3A), led],
            onChangeStart: (_) => _start(),
            onChanged: (double v) =>
                _apply(HsvIntent(hsv, white: v), live: true),
            onChangeEnd: (_) => _end(),
          ),
        );
      });

  Widget _levelSlider(AppLocalizations l) => _live((_, ChannelColor encoded) {
    final double level = encoded.maxChannel / 255;
    return _Labelled(
      label: l.level,
      value: '${(level * 100).round()} %',
      child: GlassSlider(
        elevated: false,
        value: level,
        semanticLabel: l.level,
        enabled: widget.enabled,
        divisions: 20,
        onChangeStart: (_) => _start(),
        onChanged: (double v) => _apply(
          WhiteIntent(widget.whitePoints.wK.toDouble(), v),
          live: true,
        ),
        onChangeEnd: (_) => _end(),
      ),
    );
  });

  Widget _kelvinPanel(AppLocalizations l) =>
      _live((ColourIntent intent, ChannelColor encoded) {
        final ({double min, double max}) range = _engine.whiteRange(_layout);
        final WhiteIntent w = switch (intent) {
          final WhiteIntent w => w,
          _ => switch (_engine.decode(encoded)) {
            final WhiteIntent w => w,
            _ => const WhiteIntent(4000, 1),
          },
        };
        final double k = w.kelvin.clamp(range.min, range.max);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Labelled(
              label: l.temperature,
              value: l.kelvinValue((k / 10).round() * 10),
              child: GlassSlider(
                elevated: false,
                value: k,
                min: range.min,
                max: range.max,
                semanticLabel: l.temperature,
                enabled: widget.enabled,
                valueText: (double v) => l.kelvinValue(v.round()),
                // Warm on the left, cool on the right, in the LEDs' own
                // colours.
                track: <Color>[
                  ledColor(ChannelRole.ww, widget.whitePoints),
                  ledColor(ChannelRole.cw, widget.whitePoints),
                ],
                onChangeStart: (_) => _start(),
                onChanged: (double v) =>
                    _apply(WhiteIntent(v, w.level), live: true),
                onChangeEnd: (_) => _end(),
              ),
            ),
            const SizedBox(height: Space.m),
            _Labelled(
              label: l.level,
              value: '${(w.level * 100).round()} %',
              child: GlassSlider(
                elevated: false,
                value: w.level,
                semanticLabel: l.level,
                enabled: widget.enabled,
                divisions: 20,
                onChangeStart: (_) => _start(),
                onChanged: (double v) => _apply(WhiteIntent(k, v), live: true),
                onChangeEnd: (_) => _end(),
              ),
            ),
          ],
        );
      });
}

/// One slider per LED with its exact 0..255 value.
class _Channels extends StatelessWidget {
  const _Channels({
    required this.value,
    required this.whitePoints,
    required this.onChanged,
    required this.onStart,
    required this.onEnd,
    required this.enabled,
  });
  final ChannelColor value;
  final LedWhitePoints whitePoints;
  final ColourChanged onChanged;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.of(context).dark;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(l.channels),
        children: <Widget>[
          for (int i = 0; i < value.layout.n; i++)
            // Spacing only between sliders: the last one sits as far from
            // the panel's bottom edge as the panel's padding, like the sides.
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : Space.xs),
              child: _Labelled(
                label: channelName(l, value.layout.roles[i]),
                value: '${value[i]}',
                child: GlassSlider(
                  elevated: false,
                  value: value[i].toDouble(),
                  max: 255,
                  semanticLabel: channelName(l, value.layout.roles[i]),
                  enabled: enabled,
                  track: <Color>[
                    dark ? const Color(0xFF2A2D35) : const Color(0xFFD9DCE3),
                    ledColor(value.layout.roles[i], whitePoints),
                  ],
                  valueText: (double v) => '${v.round()}',
                  onChangeStart: (_) => onStart(),
                  onChanged: (double v) =>
                      onChanged(value.withValue(i, v.round()), live: true),
                  onChangeEnd: (_) => onEnd(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A slider with its name and value above it (text inside a light
/// gradient track would be unreadable).
class _Labelled extends StatelessWidget {
  const _Labelled({
    required this.label,
    required this.value,
    required this.child,
  });
  final String label;
  final String value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Color fg = ToneScope.of(context).dark
        ? Colors.white
        : const Color(0xFF15171C);
    final TextStyle style = TextStyle(
      color: fg.withValues(alpha: 0.8),
      fontSize: 13,
      fontWeight: FontWeight.w500,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The slider announces its own name and value.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.xxs,
              0,
              Space.xxs,
              Space.xxs,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: style,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  value,
                  style: style.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Screen colour of a channel colour at full intensity (for swatches).
/// [steady]: the light's colour kept steady at low channel values (used when
/// it shows [c]).
Color swatchOf(ChannelColor c, LedWhitePoints wp, {SteadyLevels? steady}) {
  final LinearRgb lin = DisplayColor.emitted(c, wp);
  return lin.max <= 0
      ? const Color(0xFF202228)
      : screenColour(SteadyLevels.colourOf(steady, c, wp) ?? lin.normalized());
}
