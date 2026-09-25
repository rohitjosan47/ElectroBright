import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/color/color_science.dart';
import '../../core/color/colour_engine.dart';
import '../../core/color/led_white_points.dart';
import '../../core/color/light_surfaces.dart';
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
import '../../design/tone/light_level.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/fixture_session.dart';
import '../fixture_settings/light_settings_screen.dart';
import '../home/presence.dart';
import 'colour/colour_editor.dart';
import 'effects/effects_panel.dart';
import 'effects/mode_presentation.dart';
import 'presets/presets_panel.dart';
import 'timer_sheet.dart';

/// `--dart-define=EB_PERF=1` shows Flutter's performance overlay on the
/// control screen (frame timings while testing transitions and drags).
const bool _perfOverlay = String.fromEnvironment('EB_PERF') == '1';

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
  StreamSubscription<EbEvent>? _events;

  @override
  void initState() {
    super.initState();
    final AppSession? app = ref.read(appSessionProvider);
    final FixtureSession? s = app?.ble.connections.session(widget.fixtureId);
    if (app != null && s != null) {
      _want = app.ble.connections.want(widget.fixtureId, WantReason.screen);
      _events = s.events.listen(_onEvent);
    }
  }

  /// Things the light reported that are not state: say them.
  void _onEvent(EbEvent e) {
    if (!mounted) return;
    final AppLocalizations l = AppLocalizations.of(context);
    final String? message = switch (e) {
      EbStorageWarning() => l.errorStorage,
      EbOfflineChangesExpired() => l.offlineChangeNotApplied,
      EbCommandFailed(:final EbResult result)
          when result.outcome == EbOutcome.failed =>
        l.errorGeneric,
      _ => null,
    };
    if (message != null) {
      showGlassToast(context, message, icon: Icons.error_outline_rounded);
    }
  }

  @override
  void dispose() {
    _want?.release();
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture? f = ref.watch(fixtureProvider(widget.fixtureId));
    if (f == null) return const Scaffold();
    // Neither colour nor brightness frames rebuild the screen: the tone, the
    // orb, the pill and the tab body each watch what they show.
    final _ScreenState st = ref.watch(
      fixtureStatusProvider(widget.fixtureId).select(_screenState),
    );
    final LightCapabilities caps =
        ref.watch(capabilitiesProvider(widget.fixtureId)) ??
        LightCapabilities.assumed(f.layout);
    final FixtureSession? session = ref.watch(
      fixtureSessionProvider(widget.fixtureId),
    );
    final bool sleeping = st.sleeping;
    final bool ready = st.phase == LinkPhase.ready;
    final bool reconnecting =
        st.phase == LinkPhase.waiting ||
        st.phase == LinkPhase.connecting ||
        st.phase == LinkPhase.handshaking;
    // Changes made while reconnecting are replayed when the light is back.
    final bool enabled = session != null && st.known && (ready || reconnecting);

    final List<ControlTab> tabs = tabsFor(caps.colourSurface);
    final ControlTab tab = tabs.contains(_tab) ? _tab! : tabs.first;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);

    final Widget body = AmbientCanvas(
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
            live: st.live,
            sleeping: sleeping,
            fg: fg,
            onPower: enabled
                ? () => unawaited(session.setPower(on: sleeping))
                : null,
          ),
          const SizedBox(height: Space.m),
          Center(
            child: RepaintBoundary(
              child: _Orb(fixture: f, layout: caps.layout),
            ),
          ),
          if (!ready) ...<Widget>[
            const SizedBox(height: Space.s),
            _OfflineNote(fixtureId: widget.fixtureId, known: st.known, fg: fg),
          ],
          const SizedBox(height: Space.s),
          ControlToolbar(
            fixtureId: widget.fixtureId,
            session: session,
            soundOn: st.soundOn,
            sleeping: sleeping,
            enabled: enabled,
            onSettings: () => unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      LightSettingsScreen(fixtureId: widget.fixtureId),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.m),
          RepaintBoundary(
            child: BrightnessPill(
              fixtureId: widget.fixtureId,
              layout: caps.layout,
              enabled: enabled,
              fg: fg,
              session: session,
              whitePoints: f.whitePoints,
            ),
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
          _TabSwitcher(
            index: tabs.indexOf(tab),
            child: KeyedSubtree(
              key: ValueKey<ControlTab>(tab),
              child: RepaintBoundary(
                child: switch (tab) {
                  ControlTab.colour || ControlTab.white => _ColourTab(
                    fixture: f,
                    layout: caps.layout,
                    session: session,
                    enabled: enabled,
                    fg: fg,
                  ),
                  ControlTab.effects => _EffectsTab(
                    fixture: f,
                    capabilities: caps,
                    session: session,
                    enabled: enabled,
                  ),
                  ControlTab.presets => _PresetsTab(
                    fixture: f,
                    capabilities: caps,
                    session: session,
                    // Presets need the light now (no offline replay).
                    enabled: enabled && ready,
                  ),
                },
              ),
            ),
          ),
        ],
      ),
    );

    return _Tone(
      fixture: f,
      layout: caps.layout,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: _perfOverlay
            ? Stack(
                children: <Widget>[
                  body,
                  Positioned(
                    top: MediaQuery.paddingOf(context).top,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: PerformanceOverlay.allEnabled(),
                    ),
                  ),
                ],
              )
            : body,
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

/// The tab body: a new panel fades in while sliding 12 px in the direction
/// of travel (left towards a later tab) on a [Motion.snappy] spring, the old
/// one fading and sliding out; the height glides so the page doesn't jump.
/// Under Reduce Motion the panel is simply swapped.
class _TabSwitcher extends StatefulWidget {
  const _TabSwitcher({required this.index, required this.child});

  /// Position of the tab shown (sets the direction of travel).
  final int index;

  /// The panel, keyed by its tab.
  final Widget child;

  @override
  State<_TabSwitcher> createState() => _TabSwitcherState();
}

class _TabSwitcherState extends State<_TabSwitcher>
    with SingleTickerProviderStateMixin {
  static const double _slide = 12;

  /// Progress of the switch; 1 = the new panel is in place.
  late final AnimationController _t = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  Widget? _out;
  double _dir = 1;
  int _switches = 0;

  @override
  void didUpdateWidget(_TabSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.child.key == old.child.key) return;
    if (Motion.reduced(context)) {
      _t.stop();
      _t.value = 1;
      _out = null;
      return;
    }
    _out = old.child;
    _dir = widget.index >= old.index ? 1 : -1;
    final int switchNo = ++_switches;
    _t.value = 0;
    _t
        .animateWith(
          // Done once the rest is invisible (0.06 px, 0.5 % opacity), so the
          // two panels overlap for as few frames as possible.
          SpringSimulation(
            Motion.snappy,
            0,
            1,
            0,
            tolerance: const Tolerance(distance: 0.005, velocity: 0.05),
          ),
        )
        .whenCompleteOrCancel(() {
          // Only the latest switch clears its outgoing panel.
          if (mounted && switchNo == _switches) setState(() => _out = null);
        });
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget panels = AnimatedBuilder(
      animation: _t,
      builder: (BuildContext context, _) {
        final double t = _t.value.clamp(0.0, 1.0);
        final Widget? out = _out;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // The old panel on top of the list's flow, so the height
            // follows the new one.
            if (out != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 1 - t,
                    child: Transform.translate(
                      offset: Offset(-_dir * _slide * t, 0),
                      child: out,
                    ),
                  ),
                ),
              ),
            Opacity(
              opacity: out == null ? 1 : t,
              child: Transform.translate(
                offset: Offset(out == null ? 0 : _dir * _slide * (1 - t), 0),
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
    // Reduce Motion: no height glide either (a zero-length AnimatedSize
    // would finish inside its own layout).
    if (Motion.reduced(context)) return panels;
    return AnimatedSize(
      duration: Motion.medium,
      curve: Motion.emphasized,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.none,
      child: panels,
    );
  }
}

/// What the control screen itself shows of a light's status: no colour, no
/// brightness (those change every frame of a drag).
typedef _ScreenState = ({
  LinkPhase phase,
  bool live,
  bool known,
  bool sleeping,
  bool soundOn,
});

_ScreenState _screenState(FixtureStatus s) => (
  phase: s.phase,
  live: s.isReady,
  known: s.state != null,
  sleeping: s.state?.sleeping ?? false,
  soundOn: s.state?.soundOn ?? false,
);

/// The light's look without its brightness (the pill's alone): its scene at
/// full, or the factory look while nothing is known (never connected).
EbScene _lookOf(FixtureStatus s, ChannelLayout layout) {
  final EbScene? scene = s.state?.scene;
  return (scene != null && scene.layout == layout
          ? scene
          : EbScene.defaults(layout))
      .copyWith(brightness: 255);
}

/// The screen's palette, from the light's colour and whether it sleeps.
class _Tone extends ConsumerWidget {
  const _Tone({
    required this.fixture,
    required this.layout,
    required this.child,
  });
  final Fixture fixture;
  final ChannelLayout layout;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({EbScene look, bool sleeping}) t = ref.watch(
      fixtureStatusProvider(fixture.id).select(
        (FixtureStatus s) =>
            (look: _lookOf(s, layout), sleeping: s.state?.sleeping ?? false),
      ),
    );
    return ToneScope(
      tone: LightTone.derive(
        DisplayColor.ofScene(
          t.look,
          sleeping: t.sleeping,
          whitePoints: fixture.whitePoints,
        ),
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
      child: _LevelGlide(fixtureId: fixture.id, layout: layout, child: child),
    );
  }
}

/// The brightness the pill shows (0 while sleeping), gliding on a
/// Motion.smooth spring for the canvas and the orb (LightLevel). Listening,
/// not watching: brightness frames never rebuild the screen.
class _LevelGlide extends ConsumerStatefulWidget {
  const _LevelGlide({
    required this.fixtureId,
    required this.layout,
    required this.child,
  });
  final String fixtureId;
  final ChannelLayout layout;
  final Widget child;

  @override
  ConsumerState<_LevelGlide> createState() => _LevelGlideState();
}

class _LevelGlideState extends ConsumerState<_LevelGlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _level = AnimationController.unbounded(
    vsync: this,
    value: _target(ref.read(fixtureStatusProvider(widget.fixtureId))),
  );

  /// Never connected: shown at full, like the factory look it displays.
  double _target(FixtureStatus s) {
    final EbDeviceState? st = s.state;
    if (st == null || st.scene.layout != widget.layout) return 1;
    return st.sleeping ? 0 : st.scene.brightness / 255;
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual<double>(
      fixtureStatusProvider(widget.fixtureId).select(_target),
      (_, double target) => _glide(target),
    );
  }

  void _glide(double target) {
    if (Motion.reduced(context)) {
      _level
        ..stop()
        ..value = target;
      return;
    }
    unawaited(
      _level.animateWith(
        SpringSimulation(Motion.smooth, _level.value, target, _level.velocity),
      ),
    );
  }

  @override
  void dispose() {
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LightLevel(level: _level, child: widget.child);
}

/// The light as an orb: its effect, colour and whether it shines.
class _Orb extends ConsumerWidget {
  const _Orb({required this.fixture, required this.layout});
  final Fixture fixture;
  final ChannelLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({EbScene look, bool on, bool known}) o = ref.watch(
      fixtureStatusProvider(fixture.id).select(
        (FixtureStatus s) => (
          look: _lookOf(s, layout),
          on:
              s.state != null &&
              !s.state!.sleeping &&
              s.state!.scene.brightness > 0,
          known: s.state != null,
        ),
      ),
    );
    final EbModeSpec mode = presentMode(
      EbModeCatalog.byId(o.look.mode),
      layout,
      fixture.whitePoints,
      AppLocalizations.of(context),
    );
    return LightOrb(
      spec: mode,
      color: swatchOf(o.look.color, fixture.whitePoints),
      on: o.on,
      // Known lights follow their brightness; unknown ones stay dimmed.
      level: o.known ? LightLevel.of(context) : null,
      size: 160,
      speed: mode.hasSpeed ? 0.5 + o.look.speed / 10 : 1,
    );
  }
}

/// Effects follow the whole look except brightness.
class _EffectsTab extends ConsumerWidget {
  const _EffectsTab({
    required this.fixture,
    required this.capabilities,
    required this.session,
    required this.enabled,
  });
  final Fixture fixture;
  final LightCapabilities capabilities;
  final FixtureSession? session;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EffectsPanel(
    scene: ref.watch(
      fixtureStatusProvider(fixture.id)
          .select((FixtureStatus s) => _lookOf(s, capabilities.layout)),
    ),
    capabilities: capabilities,
    whitePoints: fixture.whitePoints,
    session: session,
    enabled: enabled,
  );
}

/// Why the controls are dimmed (connecting, offline...).
class _OfflineNote extends ConsumerWidget {
  const _OfflineNote({
    required this.fixtureId,
    required this.known,
    required this.fg,
  });
  final String fixtureId;
  final bool known;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    return Text(
      known
          ? l.offlineNote
          : presenceText(l, ref.watch(fixtureStatusProvider(fixtureId))),
      key: const ValueKey<String>('offline-note'),
      textAlign: TextAlign.center,
      style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 13),
    );
  }
}

/// Presets compare against the whole look, brightness included.
class _PresetsTab extends ConsumerWidget {
  const _PresetsTab({
    required this.fixture,
    required this.capabilities,
    required this.session,
    required this.enabled,
  });
  final Fixture fixture;
  final LightCapabilities capabilities;
  final FixtureSession? session;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EbDeviceState? state = ref.watch(
      fixtureStatusProvider(fixture.id).select((FixtureStatus s) => s.state),
    );
    final EbScene? known = state?.scene;
    return PresetsPanel(
      fixtureId: fixture.id,
      scene: known != null && known.layout == capabilities.layout
          ? known
          : EbScene.defaults(capabilities.layout),
      onLight: state?.presets ?? const <int>{},
      capabilities: capabilities,
      whitePoints: fixture.whitePoints,
      session: session,
      enabled: enabled,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.fixture,
    required this.live,
    required this.sleeping,
    required this.fg,
    required this.onPower,
  });
  final Fixture fixture;
  final bool live;
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
          active: live && !sleeping,
          haptic: sleeping ? HapticEvent.powerOn : HapticEvent.powerOff,
          onPressed: onPower,
        ),
      ],
    );
  }
}

/// The brightness pill's fill: the light's colour, lifted to read as a glow
/// on glass; a white (almost no chroma) takes its temperature's tint.
Color _pillFill(Color swatch, {required bool dark}) {
  final LinearRgb lin = ColorScience.fromArgb(swatch.toARGB32());
  Oklch o = ColorScience.toOklch(lin);
  if (o.c < 0.04) {
    final double k = ColorScience.estimateKelvin(lin);
    o = Oklch(o.l, 0.06, k < 4500 ? 70 : 245);
  }
  o = Oklch(o.l.clamp(dark ? 0.58 : 0.62, dark ? 0.8 : 0.82), o.c, o.h);
  return Color(
    ColorScience.toArgb(
      ColorScience.fromOklch(ColorScience.toGamut(o)).clamp01(),
    ),
  );
}

/// Brightness (on a single-white light: its intensity). 0 turns the light
/// off on release. A sleeping light shows 0 (the brightness it wakes to is
/// kept by the session). On a single-white light whose channel is below full,
/// the caption shows the real output and offers to move it all into the pill;
/// its row is always laid out so the pill never moves.
class BrightnessPill extends ConsumerWidget {
  const BrightnessPill({
    required this.fixtureId,
    required this.layout,
    required this.enabled,
    required this.fg,
    required this.session,
    this.whitePoints = const LedWhitePoints(),
    super.key,
  });

  final String fixtureId;
  final ChannelLayout layout;
  final bool enabled;
  final Color fg;
  final FixtureSession? session;
  final LedWhitePoints whitePoints;

  /// What the pill says: "Off" at 0 (released there, or asleep), otherwise
  /// the percentage, never "0 %" while the light still gives some light.
  static String label(AppLocalizations l, double x) =>
      x <= 0 ? l.brightnessOff : '${math.max(1, (x * 100).round())} %';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final ({int brightness, int level, bool sleeping, EbScene look}) p = ref
        .watch(
          fixtureStatusProvider(fixtureId).select((FixtureStatus s) {
            final EbScene? scene = s.state?.scene;
            final bool known = scene != null && scene.layout == layout;
            return (
              brightness: known ? scene.brightness : 255,
              level: known ? scene.color[0] : 255,
              sleeping: s.state?.sleeping ?? false,
              look: _lookOf(s, layout),
            );
          }),
        );
    final bool single = layout == ChannelLayout.w;
    final int brightness = p.sleeping ? 0 : p.brightness;
    final FixtureSession? s = enabled ? session : null;
    final bool partial = single && p.level < 255 && brightness > 0;
    final bool dark = ToneScope.darkOf(context);
    // The light's own colour, as the orb shows it.
    final EbModeSpec mode = presentMode(
      EbModeCatalog.byId(p.look.mode),
      layout,
      whitePoints,
      l,
    );
    final Color swatch = mode.colorUse == EbColorUse.never
        ? Color(mode.gradient.first)
        : swatchOf(p.look.color, whitePoints);
    // Light: saturated (whites a neutral mid-tone), >= 3:1 on the track.
    final LightSurfaces? light = dark
        ? null
        : LightSurfaces(ToneScope.of(context));
    // Light: the light's own colour, painted luminous by the slider; its ink
    // (dark or white, >= 4.5:1 on every part of the fill).
    final Color fill = light == null ? _pillFill(swatch, dark: dark) : swatch;
    final Color onFill = light != null
        ? Color(light.luminous(swatch.toARGB32()).ink)
        : fill.computeLuminance() > 0.45
        ? const Color(0xFF15171C)
        : Colors.white;
    // Dimmed, but on light surfaces never below 4.5:1.
    final double dimFloor = dark ? 0 : LightSurfaces.dimAlpha;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GlassSlider(
          key: const ValueKey<String>('brightness'),
          value: brightness / 255,
          semanticLabel: single ? l.intensity : l.brightness,
          enabled: s != null,
          height: 56,
          fill: fill,
          // Light: real liquid glass over the canvas (dark keeps the panel).
          glassTier: dark ? GlassTier.panel : GlassTier.chrome,
          valueText: (double x) => label(l, x),
          // The sun follows the level: small and faint low, full at the top.
          leadingBuilder: (double x, double width) {
            final bool overFill = x * width >= Space.m + 24;
            return SizedBox.square(
              dimension: 24,
              child: Center(
                child: Icon(
                  Icons.wb_sunny_outlined,
                  key: const ValueKey<String>('brightness-icon'),
                  size: 15 + 6 * x,
                  color: (overFill ? onFill : fg).withValues(
                    alpha: math.max(dimFloor, x <= 0 ? 0.4 : 0.55 + 0.45 * x),
                  ),
                ),
              ),
            );
          },
          trailingBuilder: (double x, double width) {
            final bool overFill = x * width >= width - Space.m - 20;
            return Text(
              label(l, x),
              style: TextStyle(
                color: (overFill ? onFill : fg).withValues(
                  alpha: x <= 0 ? math.max(dimFloor, 0.6) : 1,
                ),
                fontWeight: FontWeight.w500,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            );
          },
          onChangeStart: (_) => s?.beginGesture(EbKeys.brightness),
          onChanged: (double x) =>
              s?.setBrightness((x * 255).round(), live: true),
          onChangeEnd: (double x) {
            s?.setBrightness((x * 255).round());
            s?.endGesture(EbKeys.brightness);
          },
        ),
        if (single)
          AnimatedOpacity(
            key: const ValueKey<String>('output-row'),
            opacity: partial ? 1 : 0,
            duration: Motion.reduced(context) ? Duration.zero : Motion.fast,
            child: IgnorePointer(
              ignoring: !partial,
              child: ExcludeSemantics(
                excluding: !partial,
                child: Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          l.outputPercent(
                            (ColourEngine.output(p.level, brightness) * 100)
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
                        // Same light output, all of it on the pill: channel
                        // to full, brightness scaled down, in one frame.
                        onPressed: s == null || !partial
                            ? null
                            : () => s.setLook(
                                color: ChannelColor(
                                  ChannelLayout.w,
                                  const <int>[255],
                                ),
                                brightness: (p.level * brightness / 255)
                                    .round()
                                    .clamp(1, 255),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The colour controls: they follow only the light's colour (and whether
/// its effect uses it).
class _ColourTab extends ConsumerWidget {
  const _ColourTab({
    required this.fixture,
    required this.layout,
    required this.session,
    required this.enabled,
    required this.fg,
  });
  final Fixture fixture;
  final ChannelLayout layout;
  final FixtureSession? session;
  final bool enabled;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final ({ChannelColor color, bool ignored}) c = ref.watch(
      fixtureStatusProvider(fixture.id).select((FixtureStatus s) {
        final EbScene look = _lookOf(s, layout);
        return (
          color: look.color,
          ignored: !EbModeCatalog.usesPickedColor(look),
        );
      }),
    );
    final FixtureSession? s = enabled ? session : null;
    final bool ignored = c.ignored;
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
            value: c.color,
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
