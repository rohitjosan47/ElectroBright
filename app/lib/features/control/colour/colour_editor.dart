import 'package:flutter/material.dart';

import '../../../core/color/color_science.dart';
import '../../../core/color/colour_engine.dart';
import '../../../core/color/led_white_points.dart';
import '../../../core/color/light_tone.dart';
import '../../../core/model/channel_color.dart';
import '../../../core/model/channel_layout.dart';
import '../../../core/model/light_capabilities.dart';
import '../../../design/components/fixture_type.dart';
import '../../../design/components/glass_controls.dart';
import '../../../design/controls/glass_slider.dart';
import '../../../design/controls/hue_wheel.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';

/// Called with the new colour; [live] while a finger is still dragging.
typedef ColourChanged = void Function(ChannelColor color, {required bool live});

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

class _ColourEditorState extends State<ColourEditor> {
  late ColourEngine _engine = ColourEngine(widget.whitePoints);
  late ChannelColor _encoded = widget.value;
  late ColourIntent _intent = _engine.decode(widget.value);

  ChannelLayout get _layout => widget.value.layout;

  @override
  void didUpdateWidget(ColourEditor old) {
    super.didUpdateWidget(old);
    if (widget.whitePoints != old.whitePoints) {
      _engine = ColourEngine(widget.whitePoints);
    }
    if (widget.value != _encoded) {
      _encoded = widget.value;
      _intent = _engine.decode(widget.value, hint: _intent);
    }
  }

  void _apply(ColourIntent i, {required bool live}) {
    final ChannelColor c = _engine.encode(i, _layout);
    setState(() {
      _intent = i;
      _encoded = c;
    });
    widget.onChanged(c, live: live);
  }

  void _start() => widget.onGestureStart?.call();

  void _end() {
    widget.onChanged(_encoded, live: false);
    widget.onGestureEnd?.call();
  }

  _Sub get _sub => switch (_intent) {
    WhiteIntent() => _Sub.white,
    RawIntent() => _Sub.custom,
    HsvIntent() => _Sub.colour,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final ColourSurface surface = LightCapabilities.assumed(_layout)
        .colourSurface;
    final List<Widget> children = switch (surface) {
      ColourSurface.intensity => <Widget>[_levelSlider(l)],
      ColourSurface.tunableWhite => <Widget>[_kelvinPanel(l)],
      ColourSurface.colour => <Widget>[_wheel(), _chips(l)],
      ColourSurface.colourPlusWhite => <Widget>[
        _wheel(),
        const SizedBox(height: Space.m),
        _whiteLedSlider(l),
        _chips(l),
      ],
      ColourSurface.colourPlusTunableWhite => <Widget>[
        GlassSegmented<_Sub>(
          segments: <(_Sub, String)>[
            (_Sub.colour, l.tabColour),
            (_Sub.white, l.tabWhite),
            if (_sub == _Sub.custom) (_Sub.custom, l.tabCustom),
          ],
          selected: _sub,
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
        if (widget.showChannels && surface != ColourSurface.intensity)
          _Channels(
            value: _encoded,
            whitePoints: widget.whitePoints,
            enabled: widget.enabled,
            onStart: _start,
            onEnd: _end,
            onChanged: (ChannelColor c, {required bool live}) =>
                _apply(RawIntent(c), live: live),
          ),
      ],
    );
  }

  Widget _wheel() {
    final Hsv hsv = switch (_intent) {
      HsvIntent(:final Hsv hsv) => hsv,
      _ => Hsv.fromRgb8(_encoded[0], _encoded[1], _encoded[2]),
    };
    final double white = switch (_intent) {
      HsvIntent(:final double white) => white,
      _ => 0,
    };
    return HueWheel(
      value: hsv,
      enabled: widget.enabled,
      onChangeStart: _start,
      onChanged: (Hsv v) => _apply(HsvIntent(v, white: white), live: true),
      onChangeEnd: (_) => _end(),
    );
  }

  Widget _whiteLedSlider(AppLocalizations l) {
    final Hsv hsv = switch (_intent) {
      HsvIntent(:final Hsv hsv) => hsv,
      _ => Hsv.fromRgb8(_encoded[0], _encoded[1], _encoded[2]),
    };
    final double white = _encoded.role(ChannelRole.w) / 255;
    final Color led = ledColor(ChannelRole.w, widget.whitePoints);
    return _Labelled(
      label: l.whiteLed,
      value: '${(white * 100).round()} %',
      child: GlassSlider(
        value: white,
        semanticLabel: l.whiteLed,
        enabled: widget.enabled,
        track: <Color>[const Color(0xFF3A3A3A), led],
        onChangeStart: (_) => _start(),
        onChanged: (double v) => _apply(HsvIntent(hsv, white: v), live: true),
        onChangeEnd: (_) => _end(),
      ),
    );
  }

  Widget _levelSlider(AppLocalizations l) {
    final double level = _encoded.maxChannel / 255;
    return _Labelled(
      label: l.level,
      value: '${(level * 100).round()} %',
      child: GlassSlider(
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
  }

  Widget _kelvinPanel(AppLocalizations l) {
    final ({double min, double max}) range = _engine.whiteRange(_layout);
    final WhiteIntent w = switch (_intent) {
      final WhiteIntent w => w,
      _ =>
        _engine.decode(_encoded) is WhiteIntent
            ? _engine.decode(_encoded) as WhiteIntent
            : const WhiteIntent(4000, 1),
    };
    final double k = w.kelvin.clamp(range.min, range.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Labelled(
          label: l.temperature,
          value: l.kelvinValue((k / 10).round() * 10),
          child: GlassSlider(
            value: k,
            min: range.min,
            max: range.max,
            semanticLabel: l.temperature,
            enabled: widget.enabled,
            valueText: (double v) => l.kelvinValue(v.round()),
            // Warm on the left, cool on the right, in the LEDs' own colours.
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
        const SizedBox(height: Space.s),
        _whiteChips(l, range, w.level),
        const SizedBox(height: Space.s),
        _Labelled(
          label: l.level,
          value: '${(w.level * 100).round()} %',
          child: GlassSlider(
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
  }

  Widget _whiteChips(
    AppLocalizations l,
    ({double min, double max}) range,
    double level,
  ) {
    String name(String id) => switch (id) {
      'candle' => l.chipCandle,
      'warm' => l.chipWarm,
      'neutral' => l.chipNeutral,
      _ => l.chipDaylight,
    };
    return Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: <Widget>[
        for (final WhitePreset p in ColourEngine.whitePresets)
          ActionChip(
            label: Text(
              p.kelvin < range.min || p.kelvin > range.max
                  // Beyond the LEDs: the nearest end ("≈ 2700 K").
                  ? '${name(p.id)} ${l.kelvinApprox(p.kelvin.clamp(range.min, range.max).round())}'
                  : '${name(p.id)} ${l.kelvinValue(p.kelvin)}',
            ),
            onPressed: widget.enabled
                ? () {
                    _start();
                    _apply(
                      WhiteIntent(p.kelvin.toDouble(), level <= 0 ? 1 : level),
                      live: false,
                    );
                    widget.onGestureEnd?.call();
                  }
                : null,
          ),
      ],
    );
  }

  /// White chips on lights that make white from RGB (RGB, RGBW).
  Widget _chips(AppLocalizations l) => Padding(
    padding: const EdgeInsets.only(top: Space.s),
    child: _whiteChips(l, (min: 1900, max: 10000), 1),
  );
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
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: _Labelled(
                label: channelName(l, value.layout.roles[i]),
                value: '${value[i]}',
                child: GlassSlider(
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

/// Screen colour of a channel colour (for swatches).
Color swatchOf(ChannelColor c, LedWhitePoints wp) {
  final LinearRgb lin = DisplayColor.emitted(c, wp);
  return lin.max <= 0
      ? const Color(0xFF202228)
      : Color(ColorScience.toArgb(lin.normalized()));
}
