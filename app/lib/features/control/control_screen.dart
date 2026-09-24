import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/color/colour_engine.dart';
import '../../core/color/light_tone.dart';
import '../../core/model/channel_color.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/fixture.dart';
import '../../core/model/light_capabilities.dart';
import '../../core/protocol/eb/eb_scene.dart';
import '../../core/protocol/eb/mode_catalog.dart';
import '../../design/canvas/ambient_canvas.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/controls/glass_slider.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/haptics/haptics.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/fixture_session.dart';
import '../home/presence.dart';
import 'colour/colour_editor.dart';
import 'effects/effects_panel.dart';
import 'effects/mode_presentation.dart';

/// The tabs a light gets, from what it can do.
enum ControlTab { colour, white, effects, presets }

/// Tabs for [surface]: a single-white light has no colour tab (the
/// brightness pill is its only intensity), a tunable-white light gets White.
List<ControlTab> tabsFor(ColourSurface surface) => switch (surface) {
  ColourSurface.intensity => const <ControlTab>[
    ControlTab.effects,
    ControlTab.presets,
  ],
  ColourSurface.tunableWhite => const <ControlTab>[
    ControlTab.white,
    ControlTab.effects,
    ControlTab.presets,
  ],
  _ => const <ControlTab>[
    ControlTab.colour,
    ControlTab.effects,
    ControlTab.presets,
  ],
};

/// One light: orb, brightness, and controls built from its capabilities.
class ControlScreen extends ConsumerStatefulWidget {
  const ControlScreen({required this.fixtureId, super.key});
  final String fixtureId;

  @override
  ConsumerState<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends ConsumerState<ControlScreen> {
  Want? _want;
  ControlTab? _tab;

  @override
  void initState() {
    super.initState();
    final AppSession? app = ref.read(appSessionProvider);
    if (app != null && app.ble.connections.session(widget.fixtureId) != null) {
      _want = app.ble.connections.want(widget.fixtureId, WantReason.screen);
    }
  }

  @override
  void dispose() {
    _want?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture? f = ref.watch(fixtureProvider(widget.fixtureId));
    if (f == null) return const Scaffold();
    final FixtureStatus st = ref.watch(fixtureStatusProvider(widget.fixtureId));
    final LightCapabilities caps =
        ref.watch(capabilitiesProvider(widget.fixtureId)) ??
        LightCapabilities.assumed(f.layout);
    final FixtureSession? session = ref.watch(
      fixtureSessionProvider(widget.fixtureId),
    );
    final EbScene? known = st.state?.scene;
    // Nothing known yet (never connected): the light's factory look, disabled.
    final EbScene scene = known != null && known.layout == caps.layout
        ? known
        : EbScene.defaults(caps.layout);
    final bool sleeping = st.state?.sleeping ?? false;
    final bool ready = st.phase == LinkPhase.ready;
    final bool reconnecting =
        st.phase == LinkPhase.waiting ||
        st.phase == LinkPhase.connecting ||
        st.phase == LinkPhase.handshaking;
    // Changes made while reconnecting are replayed when the light is back.
    final bool enabled =
        session != null && known != null && (ready || reconnecting);

    final List<ControlTab> tabs = tabsFor(caps.colourSurface);
    final ControlTab tab = tabs.contains(_tab) ? _tab! : tabs.first;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final LightTone tone = LightTone.derive(
      DisplayColor.ofScene(
        scene,
        sleeping: sleeping,
        whitePoints: f.whitePoints,
      ),
      dark: dark,
    );
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final EbModeSpec mode = presentMode(
      EbModeCatalog.byId(scene.mode),
      caps.layout,
      f.whitePoints,
      l,
    );

    return ToneScope(
      tone: tone,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AmbientCanvas(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              Space.gutter,
              MediaQuery.paddingOf(context).top + Space.s,
              Space.gutter,
              MediaQuery.paddingOf(context).bottom + Space.gutter,
            ),
            children: <Widget>[
              _Header(
                fixture: f,
                status: st,
                sleeping: sleeping,
                fg: fg,
                onPower: enabled
                    ? () => unawaited(session.setPower(on: sleeping))
                    : null,
              ),
              const SizedBox(height: Space.m),
              Center(
                child: LightOrb(
                  spec: mode,
                  color: swatchOf(scene.color, f.whitePoints),
                  on: !sleeping && scene.brightness > 0 && known != null,
                  size: 160,
                  speed: mode.hasSpeed ? 0.5 + scene.speed / 10 : 1,
                ),
              ),
              if (!ready) ...<Widget>[
                const SizedBox(height: Space.s),
                Text(
                  known == null ? presenceText(l, st) : l.offlineNote,
                  key: const ValueKey<String>('offline-note'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: Space.m),
              BrightnessPill(
                scene: scene,
                enabled: enabled,
                fg: fg,
                session: session,
              ),
              const SizedBox(height: Space.m),
              GlassSegmented<ControlTab>(
                segments: <(ControlTab, String)>[
                  for (final ControlTab t in tabs) (t, _tabName(l, t)),
                ],
                selected: tab,
                onChanged: (ControlTab t) => setState(() => _tab = t),
              ),
              const SizedBox(height: Space.m),
              switch (tab) {
                ControlTab.colour || ControlTab.white => _ColourTab(
                  scene: scene,
                  fixture: f,
                  session: session,
                  enabled: enabled,
                  fg: fg,
                ),
                ControlTab.effects => EffectsPanel(
                  scene: scene,
                  capabilities: caps,
                  whitePoints: f.whitePoints,
                  session: session,
                  enabled: enabled,
                ),
                ControlTab.presets => const SizedBox.shrink(),
              },
            ],
          ),
        ),
      ),
    );
  }

  static String _tabName(AppLocalizations l, ControlTab t) => switch (t) {
    ControlTab.colour => l.tabColour,
    ControlTab.white => l.tabWhite,
    ControlTab.effects => l.tabEffects,
    ControlTab.presets => l.tabPresets,
  };
}

class _Header extends StatelessWidget {
  const _Header({
    required this.fixture,
    required this.status,
    required this.sleeping,
    required this.fg,
    required this.onPower,
  });
  final Fixture fixture;
  final FixtureStatus status;
  final bool sleeping;
  final Color fg;
  final VoidCallback? onPower;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return Row(
      children: <Widget>[
        GlassIconButton(
          icon: Icons.chevron_left_rounded,
          label: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: Space.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                fixture.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: Space.xxs),
              FixtureTypeBadge(
                layout: fixture.layout,
                whitePoints: fixture.whitePoints,
              ),
            ],
          ),
        ),
        const SizedBox(width: Space.s),
        GlassIconButton(
          icon: Icons.power_settings_new_rounded,
          label: sleeping ? l.powerOn : l.powerOff,
          active: status.isReady && !sleeping,
          haptic: sleeping ? HapticEvent.powerOn : HapticEvent.powerOff,
          onPressed: onPower,
        ),
      ],
    );
  }
}

/// Brightness (on a single-white light: its intensity). 0 turns the light
/// off on release. On a single-white light whose channel is below full, the
/// caption shows the real output and offers to move it all into the pill.
class BrightnessPill extends StatelessWidget {
  const BrightnessPill({
    required this.scene,
    required this.enabled,
    required this.fg,
    required this.session,
    super.key,
  });

  final EbScene scene;
  final bool enabled;
  final Color fg;
  final FixtureSession? session;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool single = scene.layout == ChannelLayout.w;
    final int level = scene.color[0];
    final FixtureSession? s = enabled ? session : null;
    final double v = scene.brightness / 255;
    final bool partial = single && level < 255 && scene.brightness > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GlassSlider(
          key: const ValueKey<String>('brightness'),
          value: v,
          semanticLabel: single ? l.intensity : l.brightness,
          enabled: s != null,
          height: 56,
          valueText: (double x) => '${(x * 100).round()} %',
          leading: Icon(Icons.wb_sunny_outlined, color: fg, size: 20),
          trailing: Text(
            '${(v * 100).round()} %',
            style: TextStyle(
              color: fg,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          onChangeStart: (_) => s?.beginGesture(EbKeys.brightness),
          onChanged: (double x) =>
              s?.setBrightness((x * 255).round(), live: true),
          onChangeEnd: (double x) {
            s?.setBrightness((x * 255).round());
            s?.endGesture(EbKeys.brightness);
          },
        ),
        if (partial)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l.outputPercent(
                      (ColourEngine.output(level, scene.brightness) * 100)
                          .round(),
                    ),
                    key: const ValueKey<String>('output-caption'),
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ),
                ActionChip(
                  label: Text(l.useFullRange),
                  // Same light output, all of it on the pill: channel to
                  // full, brightness scaled down, in one frame.
                  onPressed: s == null
                      ? null
                      : () => s.setLook(
                          color: ChannelColor(ChannelLayout.w, const <int>[
                            255,
                          ]),
                          brightness: (level * scene.brightness / 255)
                              .round()
                              .clamp(1, 255),
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ColourTab extends StatelessWidget {
  const _ColourTab({
    required this.scene,
    required this.fixture,
    required this.session,
    required this.enabled,
    required this.fg,
  });
  final EbScene scene;
  final Fixture fixture;
  final FixtureSession? session;
  final bool enabled;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final FixtureSession? s = enabled ? session : null;
    final bool ignored = !EbModeCatalog.usesPickedColor(scene);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (ignored)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: GlassSurface(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.m,
                vertical: Space.xs,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l.modeIgnoresColour,
                      style: TextStyle(color: fg, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: s == null
                        ? null
                        : () => unawaited(s.setMode(EbModeCatalog.solid)),
                    child: Text(l.switchToSolid),
                  ),
                ],
              ),
            ),
          ),
        GlassSurface(
          padding: const EdgeInsets.all(Space.m),
          child: ColourEditor(
            value: scene.color,
            whitePoints: fixture.whitePoints,
            enabled: s != null,
            onGestureStart: () => s?.beginGesture(EbKeys.color),
            onGestureEnd: () => s?.endGesture(EbKeys.color),
            onChanged: (ChannelColor c, {required bool live}) =>
                s?.setColor(c, live: live),
          ),
        ),
      ],
    );
  }
}
