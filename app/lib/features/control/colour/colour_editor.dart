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
    this.onFullRange,
    this.showChannels = true,
    this.enabled = true,
    this.memoryKey,
    super.key,
  });

  final ChannelColor value;

  /// The editor remembers the last colour (hue and saturation) under this
  /// key (e.g. the light's id), so a black or grey light reopened later
  /// keeps its hue instead of showing red.
  final Object? memoryKey;
  final ColourChanged onChanged;
  final LedWhitePoints whitePoints;
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  /// Tunable white has no level control (the brightness pill dims it). A
  /// white still below full level (a preset, the Channels sliders) moves to
  /// full when its temperature is next touched: [full] is that temperature
  /// at full level, and the parent moves [level] (perceptual 0..1) into the
  /// master brightness, so the light's output stays the same. Without it,
  /// the temperature keeps the level it has.
  final void Function(ChannelColor full, double level)? onFullRange;

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

  /// The RGB+CCT tab the user picked; null follows the colour.
  _Sub? _view;

  /// Last colour per [ColourEditor.memoryKey], for the app's lifetime.
  static final Map<Object, Hsv> _hsvMemory = <Object, Hsv>{};

  /// Last colour and white, restored when switching back to their tab.
  late Hsv _lastHsv = _hsvMemory[widget.memoryKey] ?? const Hsv(30, 1, 1);
  WhiteIntent _lastWhite = const WhiteIntent(4000, 1);

  ColourIntent get _intent => _model.value.intent;
  ChannelColor get _encoded => _model.value.encoded;
  ChannelLayout get _layout => widget.value.layout;

  @override
  void initState() {
    super.initState();
    _engine = ColourEngine(widget.whitePoints);
    _model = ValueNotifier<_Model>((
      // A grey or black colour keeps the last hue (never red by default).
      intent: _engine.decode(widget.value, hint: HsvIntent(_lastHsv)),
      encoded: widget.value,
    ));
    _remember(_intent);
  }

  void _remember(ColourIntent i) {
    switch (i) {
      case HsvIntent(:final Hsv hsv) when hsv.v > 0:
        _lastHsv = hsv;
        final Object? key = widget.memoryKey;
        if (key != null) _hsvMemory[key] = hsv;
      case final WhiteIntent w when w.level > 0:
        _lastWhite = w;
      default:
    }
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
      _remember(_intent);
      // An outside change (preset, other app) shows its own tab; the Custom
      // view can show anything, so it stays.
      if (_view != _Sub.custom) _view = null;
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
    _remember(i);
    if (!live) _rebuild();
    widget.onChanged(c, live: live, intent: i);
  }

  void _rebuild() => setState(() => _tree = null);

  /// The white the white LEDs of [c] make, the colour LEDs ignored: the
  /// temperature never depends on RGB (a colour beside the whites would
  /// otherwise decode as a mix and the temperature fall back to a default).
  WhiteIntent _whitesOf(ChannelColor c) {
    final ChannelColor whites = c.layout == ChannelLayout.rgbcct
        ? ChannelColor(c.layout, <int>[0, 0, 0, c[3], c[4]])
        : c;
    return switch (_engine.decode(whites, hint: _lastWhite)) {
      final WhiteIntent w => w,
      _ => _lastWhite,
    };
  }

  /// The level of the white being edited (1 unless it came in lower).
  double get _whiteLevel => switch (_intent) {
    WhiteIntent(:final double level) => level,
    _ => _whitesOf(_encoded).level,
  };

  /// See [ColourEditor.onFullRange].
  void _toFullRange(double kelvin, double level) {
    final void Function(ChannelColor, double)? move = widget.onFullRange;
    if (move == null || level >= 1 - 1e-3) return;
    final WhiteIntent full = WhiteIntent(kelvin, 1);
    final ChannelColor c = _engine.encode(full, _layout);
    _model.value = (intent: full, encoded: c);
    move(c, level);
  }

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

  _Sub get _sub =>
      _view ??
      switch (_intent) {
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
            (_Sub.custom, l.tabCustom),
          ],
          selected: _sub,
          elevated: false,
          onChanged: (_Sub s) {
            if (s == _sub) return;
            _view = s;
            // Colour / White are pure: the other side goes to zero, back to
            // the last value used there. Custom keeps the light as it is
            // and mixes both from there.
            switch (s) {
              case _Sub.white:
                _apply(_lastWhite, live: false);
              case _Sub.colour:
                _apply(HsvIntent(_lastHsv), live: false);
              case _Sub.custom:
                _apply(RawIntent(_encoded), live: false);
            }
          },
        ),
        const SizedBox(height: Space.m),
        switch (_sub) {
          _Sub.white => _kelvinPanel(l),
          _Sub.colour => _wheel(),
          _Sub.custom => _mixPanel(l),
        },
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
              onChanged:
                  (ChannelColor c, {required bool live, ColourIntent? intent}) {
                    // Exact channels are a mix: shown under Custom.
                    _view = null;
                    _apply(RawIntent(c), live: live);
                  },
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

  /// RGB+CCT mix: the wheel sets the colour LEDs and the temperature
  /// sets the white LEDs (at their level; the brightness pill dims), each leaving the other side as it is.
  Widget _mixPanel(AppLocalizations l) => _live((
    ColourIntent intent,
    ChannelColor encoded,
  ) {
    final ({double min, double max}) range = _engine.whiteRange(_layout);
    final bool hasColour = encoded[0] > 0 || encoded[1] > 0 || encoded[2] > 0;
    final Hsv hsv = hasColour
        ? Hsv.fromRgb8(encoded[0], encoded[1], encoded[2], previous: _lastHsv)
        : _lastHsv.copyWith(v: 0);
    final WhiteIntent w = _whitesOf(encoded);
    final double k = w.kelvin.clamp(range.min, range.max);

    void setColour(Hsv v) {
      _lastHsv = v.v > 0 ? v : _lastHsv.copyWith(h: v.h, s: v.s);
      final List<int> rgb = v.toRgb8();
      _apply(
        RawIntent(ChannelColor(_layout, <int>[...rgb, encoded[3], encoded[4]])),
        live: true,
      );
    }

    void setWhite(double kelvin, double level) {
      final WhiteIntent nw = WhiteIntent(kelvin, level);
      if (level > 0) _lastWhite = nw;
      final ChannelColor wc = _engine.encode(nw, _layout);
      _apply(
        RawIntent(
          ChannelColor(_layout, <int>[
            encoded[0],
            encoded[1],
            encoded[2],
            wc[3],
            wc[4],
          ]),
        ),
        live: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        HueWheel(
          value: hsv,
          enabled: widget.enabled,
          onChangeStart: _start,
          onChanged: setColour,
          onChangeEnd: (_) => _end(),
        ),
        const SizedBox(height: Space.m),
        KelvinSlider(
          kelvin: k,
          min: range.min,
          max: range.max,
          whitePoints: widget.whitePoints,
          enabled: widget.enabled,
          onChangeStart: _start,
          // Moving the temperature with the whites off turns them on.
          onChanged: (double v) => setWhite(v, w.level > 0 ? w.level : 1),
          onChangeEnd: (_) => _end(),
        ),
      ],
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
          _ => _whitesOf(encoded),
        };
        final double k = w.kelvin.clamp(range.min, range.max);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            KelvinSlider(
              kelvin: k,
              min: range.min,
              max: range.max,
              whitePoints: widget.whitePoints,
              enabled: widget.enabled,
              onChangeStart: () {
                _start();
                _toFullRange(k, w.level);
              },
              onChanged: (double v) =>
                  _apply(WhiteIntent(v, _whiteLevel), live: true),
              onChangeEnd: (_) => _end(),
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
    final bool dark = ToneScope.darkOf(context);
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

/// A colour temperature from [min] to [max] K, warm on the left and cool on
/// the right in the LEDs' own colours, with its name and value above.
class KelvinSlider extends StatelessWidget {
  const KelvinSlider({
    required this.kelvin,
    required this.min,
    required this.max,
    required this.onChanged,
    this.whitePoints = const LedWhitePoints(),
    this.enabled = true,
    this.onChangeStart,
    this.onChangeEnd,
    super.key,
  });

  final double kelvin;
  final double min;
  final double max;
  final LedWhitePoints whitePoints;
  final bool enabled;
  final VoidCallback? onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Slider position 0..1 for [k]: linear in mireds, as the LEDs mix, so the
  /// centre is the point where cool and warm are both at full.
  double _posOf(double k) {
    if (!(max > min)) return 0.5;
    final double mWarm = 1e6 / min, mCool = 1e6 / max;
    return ((mWarm - 1e6 / k) / (mWarm - mCool)).clamp(0.0, 1.0);
  }

  double _kelvinAt(double pos) {
    if (!(max > min)) return min;
    final double mWarm = 1e6 / min, mCool = 1e6 / max;
    return 1e6 / (mWarm + pos * (mCool - mWarm));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return _Labelled(
      label: l.temperature,
      value: l.kelvinValue((kelvin / 10).round() * 10),
      child: GlassSlider(
        elevated: false,
        value: _posOf(kelvin),
        // The centre: cool and warm both at full (the knob snaps to it).
        marks: const <double>[0.5],
        semanticLabel: l.temperature,
        enabled: enabled,
        valueText: (double p) => l.kelvinValue(_kelvinAt(p).round()),
        track: <Color>[
          ledColor(ChannelRole.ww, whitePoints),
          ledColor(ChannelRole.cw, whitePoints),
        ],
        onChangeStart: (_) => onChangeStart?.call(),
        onChanged: (double p) => onChanged(_kelvinAt(p)),
        onChangeEnd: onChangeEnd == null
            ? null
            : (double p) => onChangeEnd!(_kelvinAt(p)),
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
    final Color fg = ToneScope.darkOf(context)
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
/// The colour the editor last held for [key] (its hue and saturation at full
/// value), or null: display only, for a preview that keeps its hue at black.
Color? rememberedHue(Object key) {
  final Hsv? hsv = _ColourEditorState._hsvMemory[key];
  if (hsv == null) return null;
  final List<int> rgb = Hsv(hsv.h, hsv.s, 1).toRgb8();
  return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
}

/// [keepHue]: no fade into graphite near black (the caller fades the
/// preview itself, keeping its hue).
Color swatchOf(
  ChannelColor c,
  LedWhitePoints wp, {
  SteadyLevels? steady,
  bool keepHue = false,
}) {
  // A colour light giving only white light shows neutral white (its white
  // LEDs never tint the colour in the app).
  if (LayoutPreview.whitesOnly(c)) {
    return screenColour(LayoutPreview.whiteLight(c, wp));
  }
  const Color graphite = Color(0xFF202228);
  final LinearRgb lin = DisplayColor.emitted(c, wp);
  if (lin.max <= 0) return graphite;
  final Color shown = screenColour(
    SteadyLevels.colourOf(steady, c, wp) ?? lin.normalized(),
  );
  // Display only: over the square's bottom edge the swatch fades into the
  // graphite it shows at black, instead of holding full colour until zero
  // and switching at once. The light's levels are not touched.
  if (keepHue) return shown;
  final double x = (c.maxChannel / 255 / 0.3).clamp(0.0, 1.0);
  return Color.lerp(graphite, shown, x * x * (3 - 2 * x))!;
}
