import 'package:flutter/material.dart';

import '../../core/color/color_science.dart';
import '../../core/color/light_surfaces.dart';
import '../../core/color/light_tone.dart';
import '../../core/protocol/eb/mode_catalog.dart';
import '../canvas/ambient_canvas.dart';
import '../components/glass_controls.dart';
import '../controls/glass_slider.dart';
import '../controls/hue_wheel.dart';
import '../glass/glass_surface.dart';
import '../tokens/tokens.dart';
import '../tone/tone_scope.dart';

/// Every design-system component on one screen (M3 visual review). The tone
/// follows the wheel, like the control screen will.
class ComponentGallery extends StatefulWidget {
  const ComponentGallery({super.key});

  @override
  State<ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends State<ComponentGallery> {
  Hsv _hsv = const Hsv(28, 0.85, 1);
  double _brightness = 0.7;
  double _white = 0.2;
  double _kelvin = 0.4;
  double _speed = 5;
  int _tab = 0;
  int _mode = 6;
  int _timer = 6;
  bool _on = true;

  static const List<Duration> _timerSteps = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 20),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
    Duration(minutes: 90),
    Duration(hours: 2),
    Duration(hours: 3),
    Duration(hours: 4),
    Duration(hours: 6),
    Duration(hours: 8),
    Duration(hours: 12),
    Duration(hours: 24),
  ];

  static String _fmt(Duration d) => d.inHours >= 1
      ? '${d.inMinutes / 60 == d.inHours ? d.inHours : (d.inMinutes / 60).toStringAsFixed(1)} h'
      : d.inMinutes >= 1
      ? '${d.inMinutes} min'
      : '${d.inSeconds} s';

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color c = _hsv.color;
    final LightTone tone = LightTone.derive(
      DisplayColor(
        ColorScience.fromArgb(c.toARGB32()).normalized(),
        _brightness,
        off: !_on,
      ),
      dark: dark,
    );
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final LightTone galleryTone = ToneScope.of(context);
    final Color? onFill = galleryTone.dark
        ? null
        : Color(LightSurfaces(galleryTone).luminous(galleryTone.accent).ink);
    return ToneScope(
      tone: tone,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AmbientCanvas(
          // Content scrolls under the status bar and home indicator; the
          // padding keeps it clear of them at rest.
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              Space.gutter,
              MediaQuery.paddingOf(context).top + Space.s,
              Space.gutter,
              MediaQuery.paddingOf(context).bottom + Space.gutter,
            ),
            children: <Widget>[
              Row(
                children: <Widget>[
                  GlassIconButton(
                    icon: Icons.chevron_left_rounded,
                    label: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const Spacer(),
                  GlassIconButton(
                    icon: Icons.power_settings_new_rounded,
                    label: _on ? 'Turn off' : 'Turn on',
                    active: _on,
                    onPressed: () => setState(() => _on = !_on),
                  ),
                ],
              ),
              const SizedBox(height: Space.m),
              Center(
                child: LightOrb(
                  spec: EbModeCatalog.byId(_mode),
                  color: c,
                  on: _on,
                  speed: 0.5 + _speed / 10,
                ),
              ),
              const SizedBox(height: Space.m),
              GlassSlider(
                value: _brightness,
                semanticLabel: 'Brightness',
                // Light: over the (deep) fill the icon takes what reads on it.
                leadingBuilder: (double x, double width) => Icon(
                  Icons.wb_sunny_outlined,
                  size: 20,
                  color: onFill != null && x * width >= Space.m + 24
                      ? onFill
                      : fg,
                ),
                trailing: Text(
                  '${(_brightness * 100).round()}%',
                  style: TextStyle(
                    color: fg,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                height: 56,
                onChanged: (double v) => setState(() => _brightness = v),
              ),
              const SizedBox(height: Space.m),
              GlassSegmented<int>(
                segments: const <(int, String)>[
                  (0, 'Colour'),
                  (1, 'Effects'),
                  (2, 'Presets'),
                ],
                selected: _tab,
                onChanged: (int t) => setState(() => _tab = t),
              ),
              const SizedBox(height: Space.m),
              GlassSurface(
                padding: const EdgeInsets.all(Space.m),
                child: Column(
                  children: <Widget>[
                    HueWheel(
                      value: _hsv,
                      onChanged: (Hsv v) => setState(() => _hsv = v),
                    ),
                    const SizedBox(height: Space.m),
                    GlassSlider(
                      value: _white,
                      semanticLabel: 'White',
                      track: const <Color>[
                        Color(0xFF3A3A3A),
                        Color(0xFFFFF4E0),
                      ],
                      onChanged: (double v) => setState(() => _white = v),
                    ),
                    const SizedBox(height: Space.s),
                    GlassSlider(
                      value: _kelvin,
                      semanticLabel: 'Colour temperature',
                      track: const <Color>[
                        Color(0xFFFFB46B),
                        Color(0xFFFFF1E0),
                        Color(0xFFCFE0FF),
                      ],
                      onChanged: (double v) => setState(() => _kelvin = v),
                    ),
                    const SizedBox(height: Space.s),
                    GlassSlider(
                      value: _speed,
                      min: 1,
                      max: 10,
                      divisions: 9,
                      semanticLabel: 'Stroke Tempo',
                      valueText: levelText,
                      leading: Text(
                        'Stroke Tempo',
                        style: TextStyle(color: fg),
                      ),
                      trailing: Text(
                        '${_speed.round()}',
                        style: TextStyle(color: fg),
                      ),
                      onChanged: (double v) => setState(() => _speed = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.m),
              GridView.count(
                // Large Dynamic Type: fewer, wider tiles so names fit.
                crossAxisCount: MediaQuery.textScalerOf(context).scale(1) > 1.5
                    ? 2
                    : 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: Space.s,
                crossAxisSpacing: Space.s,
                childAspectRatio: 0.95,
                children: <Widget>[
                  for (final EbModeSpec m in EbModeCatalog.modes)
                    ModeTile(
                      spec: m,
                      selected: m.id == _mode,
                      color: c,
                      onTap: () => setState(() => _mode = m.id),
                    ),
                ],
              ),
              const SizedBox(height: Space.m),
              GlassSurface(
                padding: const EdgeInsets.all(Space.l),
                child: TimerDial(
                  steps: _timerSteps,
                  index: _timer,
                  label: _fmt,
                  onChanged: (int i) => setState(() => _timer = i),
                ),
              ),
              const SizedBox(height: Space.m),
              Center(
                child: FilledButton(
                  onPressed: () => showGlassToast(
                    context,
                    'Preset saved',
                    icon: Icons.check_circle_rounded,
                  ),
                  child: const Text('Show toast'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
