import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/color/colour_engine.dart';
import '../../core/color/led_white_points.dart';
import '../../core/color/light_surfaces.dart';
import '../../core/color/light_tone.dart';
import '../../core/color/steady_colour.dart';
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
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/group_capabilities.dart';
import '../../sessions/group_session.dart';
import '../../sessions/rituals.dart';
import '../control/colour/colour_editor.dart';
import '../control/effects/effect_colours.dart';
import '../control/effects/effects_grid.dart';
import '../control/effects/mode_presentation.dart';
import '../control/shared/brightness_pill_slider.dart';
import '../control/shared/control_header.dart';
import '../control/shared/tab_switcher.dart';
import '../control/timer_sheet.dart';
import 'group_presets_tab.dart';

enum _GroupTab { colour, white, effects, presets }

/// Sends a group command and says how it went (one message per command).
typedef GroupRun = void Function(Future<GroupResult> command);

/// A group (Colour lights or White lights): the same settings sent at the
/// same moment to every light in it (each light keeps its own effect clock).
class GroupScreen extends ConsumerStatefulWidget {
  const GroupScreen({required this.kind, super.key});
  final GroupKind kind;

  @override
  ConsumerState<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends ConsumerState<GroupScreen> {
  GroupSession? _group;
  _GroupTab _tab = _GroupTab.colour;

  @override
  void initState() {
    super.initState();
    _group = ref.read(groupSessionProvider(widget.kind))?..activate();
  }

  @override
  void dispose() {
    _group?.deactivate();
    super.dispose();
  }

  /// One message per command: a failure, or which lights it reached when
  /// some cannot do it.
  void _run(Future<GroupResult> command) => unawaited(
    command.then((GroupResult r) {
      if (!mounted) return;
      final String? message = _messageOf(AppLocalizations.of(context), r);
      if (message != null) {
        showGlassToast(context, message, icon: Icons.info_outline_rounded);
      }
    }),
  );

  static String? _messageOf(AppLocalizations l, GroupResult r) {
    if (r.failed > 0) return l.errorGeneric;
    if (r.skipped > 0) {
      return l.groupApplied(r.ok, r.ok + r.failed + r.skipped);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupSession? group = _group;
    if (group == null) return const Scaffold();
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final bool anyOn = ref.watch(groupAnyOnProvider(group.kind));
    // The lights the group drives (not left out, not on their own
    // settings), and how many of them are connected.
    final ({int driven, int ready}) g = ref.watch(
      groupStatusProvider(group.kind).select(_drivenCounts),
    );
    final bool live = g.ready > 0;
    // White lights only (W): no White tab.
    final bool tunable = ref.watch(
      groupCapabilitiesProvider(group.kind)
          .select((GroupCapabilities c) => c.hasTunable),
    );
    final List<_GroupTab> tabs = <_GroupTab>[
      if (group.kind == GroupKind.colour) _GroupTab.colour,
      if (group.kind == GroupKind.white && tunable) _GroupTab.white,
      _GroupTab.effects,
      _GroupTab.presets,
    ];
    final _GroupTab tab = tabs.contains(_tab) ? _tab : tabs.first;
    Widget panel(_GroupTab t) => switch (t) {
      _GroupTab.colour => _GroupColourTab(group: group, enabled: live),
      _GroupTab.white => _GroupWhiteTab(group: group, enabled: live),
      _GroupTab.effects => _GroupEffectsTab(
        group: group,
        enabled: live,
        fg: fg,
        run: _run,
      ),
      _GroupTab.presets => GroupPresetsTab(
        group: group,
        enabled: live,
        run: _run,
      ),
    };
    return _GroupTone(
      kind: group.kind,
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
              ControlHeader(
                title: group.kind == GroupKind.colour
                    ? l.groupColourTitle
                    : l.groupWhiteTitle,
                subtitle: Text(
                  l.groupSubtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
                on: anyOn,
                lit: live && anyOn,
                fg: fg,
                onPower: live ? () => _run(group.setPower(on: !anyOn)) : null,
              ),
              const SizedBox(height: Space.m),
              Center(
                child: RepaintBoundary(child: _GroupOrb(kind: group.kind)),
              ),
              const SizedBox(height: Space.s),
              _StatusLine(kind: group.kind, budget: group.budget, fg: fg),
              const SizedBox(height: Space.s),
              if (g.driven == 0)
                _NoneFollowing(group: group, fg: fg)
              else ...<Widget>[
                _GroupToolbar(group: group, enabled: live && anyOn, run: _run),
                const SizedBox(height: Space.m),
                RepaintBoundary(
                  child: _GroupBrightness(group: group, enabled: live, fg: fg),
                ),
                const SizedBox(height: Space.m),
                ...<Widget>[
                  GlassSegmented<_GroupTab>(
                    segments: <(_GroupTab, String)>[
                      for (final _GroupTab t in tabs)
                        (
                          t,
                          switch (t) {
                            _GroupTab.colour => l.tabColour,
                            _GroupTab.white => l.tabWhite,
                            _GroupTab.effects => l.tabEffects,
                            _GroupTab.presets => l.tabPresets,
                          },
                        ),
                    ],
                    selected: tab,
                    thumbTier: GlassTier.chrome,
                    onChanged: (_GroupTab t) => setState(() => _tab = t),
                  ),
                  const SizedBox(height: Space.m),
                  TabSwitcher(
                    index: tabs.indexOf(tab),
                    child: KeyedSubtree(
                      key: ValueKey<_GroupTab>(tab),
                      child: RepaintBoundary(child: panel(tab)),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: Space.l),
              _GroupLights(group: group, fg: fg),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screen's palette, from the lights' common colour (or effect) and
/// whether any of them is on.
class _GroupTone extends ConsumerWidget {
  const _GroupTone({required this.kind, required this.child});
  final GroupKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final _GroupLookOf t = _groupLook(ref, kind);
    final int mode = ref.watch(
      groupModeProvider(kind)
          .select((Common<int> m) => m.value ?? EbModeCatalog.solid),
    );
    final bool anyOn = ref.watch(groupAnyOnProvider(kind));
    // The same path as a single light's screen (ControlScreen): a colour
    // group reads as a light showing its colour, a white group as one of
    // its own white lights.
    return ToneScope(
      tone: LightTone.derive(
        DisplayColor.ofScene(
          t.look.copyWith(mode: mode),
          sleeping: !anyOn,
          whitePoints: t.whitePoints,
          steady: t.steady,
        ),
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
      child: child,
    );
  }
}

typedef _GroupLookOf = ({
  EbScene look,
  LedWhitePoints whitePoints,
  SteadyLevels? steady,
});

/// The group's look at full brightness, as one light shows it:
/// - colour group: an RGB+CCT light with the lights' common colour;
/// - white group with CCT lights: a CCT light at their temperature (their
///   mean when they differ), picked, with the group's white points;
/// - W lights only: a W light at its white.
/// The steady levels are those such a light would have
/// (steadyLevelsProvider).
_GroupLookOf _groupLook(WidgetRef ref, GroupKind kind) {
  if (kind == GroupKind.colour) {
    return (
      look: EbScene.defaults(ChannelLayout.rgbcct).copyWith(
        color: ref.watch(groupColourProvider(kind).select(_groupColour)),
        brightness: 255,
      ),
      whitePoints: const LedWhitePoints(),
      steady: null,
    );
  }
  final ({LedWhitePoints wp, bool tunable}) c = ref.watch(
    groupCapabilitiesProvider(kind).select(
      (GroupCapabilities c) => (wp: c.whitePoints, tunable: c.hasTunable),
    ),
  );
  final ChannelLayout layout = c.tunable ? ChannelLayout.cct : ChannelLayout.w;
  final ColourEngine engine = ColourEngine(c.wp);
  final WhiteIntent white = WhiteIntent(
    ref.watch(groupKelvinProvider(kind)) ?? 4000,
    1,
  );
  final ChannelColor colour = c.tunable
      ? engine.encode(white, layout)
      : ChannelColor(layout, const <int>[255]);
  return (
    look: EbScene.defaults(layout).copyWith(color: colour, brightness: 255),
    whitePoints: c.wp,
    steady: c.tunable
        ? SteadyLevels.next(
            null,
            colour,
            intent: engine.fullLevels(white, layout),
          )
        : SteadyLevels.next(null, colour),
  );
}

/// What the colour group's tone starts from: the lights' common colour as
/// an RGB+CCT light makes it, else a neutral white.
ChannelColor _groupColour(Common<ColourIntent> common) {
  const ColourEngine engine = ColourEngine();
  const ChannelLayout layout = ChannelLayout.rgbcct;
  final ColourIntent? i = common.value;
  final ColourIntent shown = switch (i) {
    RawIntent(:final ChannelColor color) when color.layout != layout =>
      engine.decode(color),
    null => const WhiteIntent(4000, 1),
    _ => i,
  };
  return switch (shown) {
    RawIntent(:final ChannelColor color) when color.layout != layout =>
      engine.encode(const WhiteIntent(4000, 1), layout),
    _ => engine.encode(shown, layout),
  };
}

/// How many lights the group drives, and how many of those are connected.
({int driven, int ready}) _drivenCounts(GroupStatus s) => (
  driven: s.members.where((GroupMember m) => !m.own).length,
  ready: s.members.where((GroupMember m) => !m.own && m.isReady).length,
);

/// Up to four connected lights as small still orbs, fanned out, and how
/// many more there are.
class _GroupOrb extends ConsumerWidget {
  const _GroupOrb({required this.kind});
  final GroupKind kind;

  static const int _shown = 4;
  static const double _size = 64;
  static const double _step = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GroupStatus st = ref.watch(groupStatusProvider(kind));
    final List<String> ready = <String>[
      for (final GroupMember m in st.members)
        if (m.isReady && !m.own) m.id,
    ];
    final int n = math.min(ready.length, _shown);
    final int more = ready.length - n;
    final double width = n == 0 ? _size : _size + (n - 1) * _step;
    return Semantics(
      image: true,
      label: AppLocalizations.of(context).groupOrb(ready.length),
      child: SizedBox(
        height: _size + 16,
        width: width + (more > 0 ? 36 : 0),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            if (n == 0)
              const Positioned(left: 0, top: 8, child: _MiniOrb(id: null)),
            for (int i = 0; i < n; i++)
              Positioned(
                left: i * _step,
                // A shallow arc: the middle orbs sit a little higher.
                top: 8 - 8 * math.sin(math.pi * (i + 0.5) / n),
                child: _MiniOrb(id: ready[i]),
              ),
            if (more > 0)
              Positioned(
                right: 0,
                bottom: 0,
                child: GlassSurface(
                  radius: Radii.small,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.xs,
                    vertical: 2,
                  ),
                  child: Text(
                    '+$more',
                    style: TextStyle(
                      color: ToneScope.darkOf(context)
                          ? Colors.white
                          : const Color(0xFF15171C),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A light's steady colour as the rest of the app shows it (null before its
/// first status), and whether it is on.
({Color? colour, bool on}) _lightSwatch(WidgetRef ref, String id) {
  final ({ChannelColor? color, bool on}) s = ref.watch(
    fixtureStatusProvider(id).select(
      (FixtureStatus s) => (
        color: s.state?.scene.color,
        on:
            s.state != null &&
            !s.state!.sleeping &&
            s.state!.scene.brightness > 0,
      ),
    ),
  );
  final LedWhitePoints wp = ref.watch(
    fixtureProvider(id)
        .select((Fixture? f) => f?.whitePoints ?? const LedWhitePoints()),
  );
  final ChannelColor? c = s.color;
  return (
    colour: c == null
        ? null
        : swatchOf(c, wp, steady: ref.watch(steadyLevelsProvider(id))),
    on: s.on,
  );
}

/// One light's colour as a still orb (dim while it is off).
class _MiniOrb extends ConsumerWidget {
  const _MiniOrb({required this.id});
  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? id = this.id;
    final ({Color? colour, bool on}) s = id == null
        ? (colour: null, on: false)
        : _lightSwatch(ref, id);
    final Color colour = s.colour ?? const Color(0xFFFFF4E6);
    final bool on = s.on;
    return Opacity(
      opacity: on ? 1 : 0.3,
      child: Container(
        width: _GroupOrb._size,
        height: _GroupOrb._size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[
              Color.lerp(colour, Colors.white, 0.35)!,
              colour,
              colour.withValues(alpha: 0.5),
            ],
            stops: const <double>[0, 0.6, 1],
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(color: colour.withValues(alpha: 0.45), blurRadius: 18),
          ],
        ),
      ),
    );
  }
}

/// "4 of 5 connected · 1 connecting", and the connection budget when it
/// leaves lights out.
class _StatusLine extends ConsumerWidget {
  const _StatusLine({
    required this.kind,
    required this.budget,
    required this.fg,
  });
  final GroupKind kind;
  final int budget;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupStatus st = ref.watch(groupStatusProvider(kind));
    final ({int driven, int ready}) g = _drivenCounts(st);
    // Out of every light of the group: one left out is not connected for
    // it.
    final int saved = st.members.length + st.excluded.length;
    final TextStyle style = TextStyle(
      color: fg.withValues(alpha: 0.7),
      fontSize: 13,
    );
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        children: <Widget>[
          Text(
            g.driven > 0 && g.ready == 0
                ? <String>[
                    l.noLightsConnected,
                    if (st.connecting > 0) l.groupConnecting(st.connecting),
                  ].join(' · ')
                : <String>[
                    l.groupConnected(g.ready, saved),
                    if (st.connecting > 0) l.groupConnecting(st.connecting),
                  ].join(' · '),
            key: const ValueKey<String>('group-status'),
            textAlign: TextAlign.center,
            style: style,
          ),
          if (st.limitedOut > 0)
            Text(
              l.groupLimited(budget),
              textAlign: TextAlign.center,
              style: style,
            ),
        ],
      ),
    );
  }
}

/// The sleep timer for every light: the shared countdown, or "Timers differ".
class _GroupToolbar extends ConsumerWidget {
  const _GroupToolbar({
    required this.group,
    required this.enabled,
    required this.run,
  });
  final GroupSession group;
  final bool enabled;
  final GroupRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool differ = ref.watch(
      groupTimerProvider(group.kind).select((Common<Duration> c) => c.mixed),
    );
    Future<String?> send(int seconds) async {
      final GroupResult r = await group.setTimer(seconds);
      if (r.failed > 0) return l.errorGeneric;
      if (r.skipped > 0) run(Future<GroupResult>.value(r));
      return null;
    }

    return TimerCountdown(
      deadline: groupTimerDeadlineProvider(group.kind),
      builder: (BuildContext context, Duration? left) => Column(
        children: <Widget>[
          GlassIconButton(
            key: const ValueKey<String>('timer-button'),
            icon: Icons.timer_outlined,
            label: l.timer,
            active: left != null,
            onPressed: enabled
                ? () => unawaited(
                    showSleepTimerSheet(
                      context,
                      deadline: groupTimerDeadlineProvider(group.kind),
                      spanKey: group.timerSpanKey,
                      onStart: (Duration d) => send(d.inSeconds),
                      onCancel: () => send(0),
                    ),
                  )
                : null,
          ),
          if (left != null)
            TimerCaption(l.timerOff(countdown(left)))
          else if (differ)
            TimerCaption(l.timersDiffer),
        ],
      ),
    );
  }
}

/// The lights' common brightness; while they differ, "Mixed" over the
/// group's last master, full before the first one (never a value derived
/// from the lights).
class _GroupBrightness extends ConsumerWidget {
  const _GroupBrightness({
    required this.group,
    required this.enabled,
    required this.fg,
  });
  final GroupSession group;
  final bool enabled;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Common<int> b = ref.watch(groupBrightnessProvider(group.kind));
    final bool anyOn = ref.watch(groupAnyOnProvider(group.kind));
    final int? master = ref.watch(groupMasterProvider(group.kind));
    final int shown = (b.mixed ? master ?? 255 : b.value) ?? 0;
    return BrightnessPillSlider(
      value: anyOn ? shown / 255 : 0,
      mixed: b.mixed,
      enabled: enabled,
      fg: fg,
      onChangeStart: () => group.beginGesture(EbKeys.brightness),
      onChanged: (double x) =>
          unawaited(group.setBrightness((x * 255).round(), live: true)),
      onChangeEnd: (double x) {
        unawaited(group.setBrightness((x * 255).round()));
        group.endGesture(EbKeys.brightness);
      },
    );
  }
}

/// The colour group's colour: the wheel alone (every white LED goes to 0,
/// so all its lights match).
class _GroupColourTab extends ConsumerWidget {
  const _GroupColourTab({required this.group, required this.enabled});
  final GroupSession group;
  final bool enabled;

  static const ChannelLayout _layout = ChannelLayout.rgb;

  /// The lights' common colour on the wheel, else a neutral white.
  static ChannelColor _wheelValue(Common<ColourIntent> common) =>
      switch (common.value) {
        final HsvIntent i => const ColourEngine().encode(i, _layout),
        _ => ChannelColor(_layout, const <int>[255, 255, 255]),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ChannelColor value = ref.watch(
      groupColourProvider(group.kind).select(_wheelValue),
    );
    return GlassSurface(
      padding: const EdgeInsets.all(Space.m),
      child: ColourEditor(
        value: value,
        showChannels: false,
        enabled: enabled,
        onGestureStart: () => group.beginGesture(EbKeys.color),
        onGestureEnd: () => group.endGesture(EbKeys.color),
        onChanged:
            (ChannelColor c, {required bool live, ColourIntent? intent}) {
              if (intent is HsvIntent) {
                unawaited(group.setColour(intent, live: live));
              }
            },
      ),
    );
  }
}

/// The white group's colour temperature for its CCT lights, over the union
/// of their ranges (each light stops at its own end). No level: the
/// brightness pill dims them.
class _GroupWhiteTab extends ConsumerStatefulWidget {
  const _GroupWhiteTab({required this.group, required this.enabled});
  final GroupSession group;
  final bool enabled;

  @override
  ConsumerState<_GroupWhiteTab> createState() => _GroupWhiteTabState();
}

class _GroupWhiteTabState extends ConsumerState<_GroupWhiteTab> {
  /// The temperature under the finger while dragging.
  double? _drag;

  static double? _kelvinOf(Common<ColourIntent> common) =>
      switch (common.value) {
        WhiteIntent(:final double kelvin) => kelvin,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupSession group = widget.group;
    final ({LedWhitePoints range, bool fixedWhite}) caps = ref.watch(
      groupCapabilitiesProvider(group.kind).select(
        (GroupCapabilities c) =>
            (range: c.whitePoints, fixedWhite: c.hasFixedWhite),
      ),
    );
    final double min = caps.range.wwK.toDouble();
    final double max = caps.range.cwK.toDouble();
    final double shown =
        (_drag ??
                ref.watch(groupColourProvider(group.kind).select(_kelvinOf)) ??
                4000)
            .clamp(min, max);
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GlassSurface(
          padding: const EdgeInsets.all(Space.m),
          child: KelvinSlider(
            kelvin: shown,
            min: min,
            max: max,
            whitePoints: caps.range,
            enabled: widget.enabled,
            onChangeStart: () => group.beginGesture(EbKeys.color),
            onChanged: (double v) {
              setState(() => _drag = v);
              unawaited(group.setTemperature(v, live: true));
            },
            onChangeEnd: (double v) {
              unawaited(group.setTemperature(v));
              group.endGesture(EbKeys.color);
              setState(() => _drag = null);
            },
          ),
        ),
        if (caps.fixedWhite)
          Padding(
            padding: const EdgeInsets.only(top: Space.s, left: Space.xxs),
            child: Text(
              l.wLightsKeepWhite,
              key: const ValueKey<String>('w-lights-caption'),
              style: TextStyle(
                color: fg.withValues(
                  alpha: LightSurfaces.dim(0.7, dark: fg == Colors.white),
                ),
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// What the effects tab reads of one ready light.
typedef _LightMode = ({int mode, int speed, int frequency});

/// Every effect some light of the group has; "n/m" on those only some have.
/// An effect is lit when every connected light that has it runs it.
class _GroupEffectsTab extends ConsumerWidget {
  const _GroupEffectsTab({
    required this.group,
    required this.enabled,
    required this.fg,
    required this.run,
  });
  final GroupSession group;
  final bool enabled;
  final Color fg;
  final GroupRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupCapabilities caps = ref.watch(
      groupCapabilitiesProvider(group.kind),
    );
    final List<String> ready = ref
        .watch(
          groupStatusProvider(group.kind).select(
            (GroupStatus s) => <String>[
              for (final GroupMember m in s.members)
                if (m.isReady && !m.own) m.id,
            ].join(' '),
          ),
        )
        .split(' ')
        .where((String id) => id.isNotEmpty)
        .toList();
    final Map<String, _LightMode> lights = <String, _LightMode>{
      for (final String id in ready)
        id: ref.watch(
          fixtureStatusProvider(id).select((FixtureStatus s) {
            final int mode = s.state?.scene.mode ?? EbModeCatalog.solid;
            return (
              mode: mode,
              speed: s.state?.scene.speeds[mode - 1] ?? 5,
              frequency: s.state?.scene.frequencies[mode - 1] ?? 5,
            );
          }),
        ),
    };
    final List<int> effects = caps.effects;
    final List<EbModeSpec> modes = <EbModeSpec>[
      for (final EbModeSpec m in presentModes(
        const LightCapabilities(layout: ChannelLayout.rgbcct),
        const LedWhitePoints(),
        l,
      ))
        if (effects.contains(m.id)) m,
    ];
    final int total = caps.lights.length;
    final Map<int, String> badges = <int, String>{
      for (final EbModeSpec m in modes)
        if (caps.effectIds(m.id).length < total)
          m.id: '${caps.effectIds(m.id).length}/$total',
    };
    // Connected lights that have [mode].
    List<String> having(int mode) => <String>[
      for (final String id in caps.effectIds(mode))
        if (lights.containsKey(id)) id,
    ];
    final EbModeSpec? selected = modes.where((EbModeSpec m) {
      final List<String> h = having(m.id);
      return h.isNotEmpty && h.every((String id) => lights[id]!.mode == m.id);
    }).firstOrNull;
    final _LightMode? first = selected == null
        ? null
        : lights[having(selected.id).first];
    final _GroupLookOf look = _groupLook(ref, group.kind);
    final Color colour = swatchOf(
      look.look.color,
      look.whitePoints,
      steady: look.steady,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        EffectsGrid(
          modes: modes,
          selected: selected?.id,
          color: colour,
          badges: badges,
          // They move while the lights are on and connected.
          animate: enabled && ref.watch(groupAnyOnProvider(group.kind)),
          onSelect: (int mode) {
            if (enabled) run(group.setMode(mode));
          },
        ),
        ModeSettingsSwitcher(
          mode:
              selected != null &&
                  first != null &&
                  (selected.hasSpeed ||
                      selected.hasFrequency ||
                      (group.kind == GroupKind.colour && selected.hasColorMode))
              ? selected
              : null,
          builder: (EbModeSpec mode) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ModeSliders(
                mode: mode,
                speed: first!.speed,
                frequency: first.frequency,
                enabled: enabled,
                fg: fg,
                onSpeed: (int v) => run(group.setSpeed(mode.id, v)),
                onFrequency: (int v) => run(group.setFrequency(mode.id, v)),
              ),
              if (group.kind == GroupKind.colour && mode.colorModeKind != null)
                _GroupEffectColours(
                  group: group,
                  kind: mode.colorModeKind!,
                  enabled: enabled,
                  fg: fg,
                  run: run,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The colour group's colour source for the selected effect and, for Police
/// on its picked colours, the two beacons: the lights' common values; when
/// they differ nothing is selected (a split beacon swatch) until the first
/// change sets them all.
class _GroupEffectColours extends ConsumerWidget {
  const _GroupEffectColours({
    required this.group,
    required this.kind,
    required this.enabled,
    required this.fg,
    required this.run,
  });
  final GroupSession group;
  final EbColorModeKind kind;
  final bool enabled;
  final Color fg;
  final GroupRun run;

  static const ChannelLayout _layout = ChannelLayout.rgb;

  static ChannelColor _colourOf(Rgb c) =>
      ChannelColor(_layout, <int>[c.$1, c.$2, c.$3]);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Common<int> source = ref.watch(
      groupColorModeProvider((group.kind, kind)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: Space.m),
        ColourSourceControl(
          key: const ValueKey<String>('group-colour-source'),
          kind: kind,
          layout: _layout,
          selected: source.value,
          fg: fg,
          onChanged: (int v) {
            if (enabled) run(group.setColorMode(kind, v));
          },
        ),
        if (kind == EbColorModeKind.police && source.value == 0) ...<Widget>[
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
                    child: _beacon(context, ref, l, slot),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _beacon(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l,
    EbPoliceSlot slot,
  ) {
    final Common<Rgb> c = ref.watch(
      groupPoliceColourProvider((group.kind, slot)),
    );
    final String label = slot == EbPoliceSlot.a ? l.beaconA : l.beaconB;
    final Rgb? rgb = c.value;
    return BeaconSwatch(
      key: ValueKey<String>('group-beacon-${slot.name}'),
      label: label,
      color: rgb == null
          ? null
          : swatchOf(_colourOf(rgb), const LedWhitePoints()),
      fg: fg,
      onTap: !enabled
          ? null
          : () => unawaited(
              showBeaconSheet(
                context,
                title: label,
                start: rgb == null
                    ? ChannelColor(_layout, const <int>[255, 0, 0])
                    : _colourOf(rgb),
                whitePoints: const LedWhitePoints(),
                showChannels: false,
                onChanged: (_, ColourIntent? intent) {
                  if (intent is HsvIntent) {
                    run(group.setPoliceColor(slot, intent));
                  }
                },
              ),
            ),
    );
  }
}

/// No light follows the group: a short message and one way back.
class _NoneFollowing extends ConsumerWidget {
  const _NoneFollowing({required this.group, required this.fg});
  final GroupSession group;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool anyOwn = ref.watch(
      groupStatusProvider(group.kind)
          .select((GroupStatus s) => s.members.any((GroupMember m) => m.own)),
    );
    return GlassSurface(
      key: const ValueKey<String>('group-none-following'),
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            l.groupNoneFollowing,
            style: TextStyle(color: fg.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: Space.m),
          FilledButton(
            onPressed: group.rejoinAll,
            child: Text(anyOwn ? l.rejoinAll : l.includeLights),
          ),
        ],
      ),
    );
  }
}

/// The group's lights, one compact row each: colour, name, type and level
/// (or state), and whether it follows the group. A tapped row opens its
/// level in the group and Flash; one row at a time.
class _GroupLights extends ConsumerStatefulWidget {
  const _GroupLights({required this.group, required this.fg});
  final GroupSession group;
  final Color fg;

  @override
  ConsumerState<_GroupLights> createState() => _GroupLightsState();
}

class _GroupLightsState extends ConsumerState<_GroupLights> {
  /// The open row's light.
  String? _open;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupSession group = widget.group;
    final Color fg = widget.fg;
    // The group's lights only (a light is in one group).
    final List<Fixture> fixtures = ref.watch(
      fixturesProvider.select(
        (List<Fixture> all) => <Fixture>[
          for (final Fixture f in all)
            if (GroupKind.holds(group.kind, f)) f,
        ],
      ),
    );
    final bool anyOwn = ref.watch(
      groupStatusProvider(group.kind)
          .select((GroupStatus s) => s.members.any((GroupMember m) => m.own)),
    );
    return GlassSurface(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l.groupLights,
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (anyOwn)
                TextButton(
                  key: const ValueKey<String>('rejoin-all'),
                  onPressed: group.rejoinAll,
                  child: Text(l.rejoinAll),
                ),
            ],
          ),
          const SizedBox(height: Space.xxs),
          for (int i = 0; i < fixtures.length; i++) ...<Widget>[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                color: fg.withValues(alpha: 0.12),
              ),
            _GroupLightRow(
              key: ValueKey<String>('group-light-${fixtures[i].id}'),
              fixture: fixtures[i],
              group: group,
              fg: fg,
              open: _open == fixtures[i].id,
              onToggle: () => setState(
                () => _open = _open == fixtures[i].id ? null : fixtures[i].id,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a group row shows in place of the light's level: why the group does
/// not drive it, or its connection; null for a connected, following light
/// (it shows its level).
@visibleForTesting
String? groupRowStatus(
  AppLocalizations l,
  LinkPhase phase, {
  required bool included,
  required bool own,
  required bool limitedOut,
  bool updating = false,
}) {
  if (!included || own) return own ? l.groupOwnSettings : l.groupExcluded;
  if (limitedOut) return l.groupRowPhoneLimit;
  if (updating) return l.presenceUpdating;
  return switch (phase) {
    LinkPhase.ready => null,
    LinkPhase.connecting ||
    LinkPhase.handshaking ||
    LinkPhase.waiting => l.presenceConnecting,
    LinkPhase.unavailable ||
    LinkPhase.incompatible ||
    LinkPhase.bluetoothOff => l.groupRowUnavailable,
    LinkPhase.idle => l.presenceIdle,
  };
}

/// What a row shows of the light's place in the group.
typedef _RowState = ({bool included, bool own, bool limitedOut, double trim});

/// One light, on one line: its colour, name, type and level in the group
/// (or why it is not driven), the chevron and the include switch. Open, it
/// shows the level slider and Flash.
class _GroupLightRow extends ConsumerWidget {
  const _GroupLightRow({
    required this.fixture,
    required this.group,
    required this.fg,
    required this.open,
    required this.onToggle,
    super.key,
  });
  final Fixture fixture;
  final GroupSession group;
  final Color fg;
  final bool open;
  final VoidCallback onToggle;

  static String _percent(double t) => '${(t * 100).round()} %';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final String id = fixture.id;
    final (LinkPhase phase, bool updating) = ref.watch(
      fixtureStatusProvider(id)
          .select((FixtureStatus s) => (s.phase, s.updating)),
    );
    final _RowState g = ref.watch(
      groupStatusProvider(group.kind).select((GroupStatus s) {
        final GroupMember? m = s.members
            .where((GroupMember m) => m.id == id)
            .firstOrNull;
        return (
          included: m != null,
          own: m?.own ?? false,
          limitedOut: m?.limitedOut ?? false,
          trim: m?.trim ?? 1,
        );
      }),
    );
    final FixtureSession? session = ref.watch(fixtureSessionProvider(id));
    final bool ready = phase == LinkPhase.ready && !updating;
    final bool following = g.included && !g.own;
    final int percent = (g.trim * 100).round();
    final String type = fixtureTypeName(l, fixture.layout);
    // In place of the level when it matters; a connected, following light
    // shows its level.
    final String? status = groupRowStatus(
      l,
      phase,
      included: g.included,
      own: g.own,
      limitedOut: g.limitedOut,
      updating: updating,
    );
    final TextStyle small = TextStyle(
      color: fg.withValues(alpha: 0.6),
      fontSize: 12,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                container: true,
                button: true,
                expanded: open,
                label: l.groupLightRow(
                  fixture.name,
                  type,
                  percent,
                  following
                      ? l.groupRowFollowing
                      : g.own
                      ? l.groupRowOwn
                      : l.groupRowExcluded,
                ),
                hint: open ? l.groupRowCollapseHint : l.groupRowExpandHint,
                onTap: onToggle,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    key: ValueKey<String>('row-$id'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggle,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.xs),
                      child: Row(
                        children: <Widget>[
                          _LightDot(
                            key: ValueKey<String>('dot-$id'),
                            id: ready ? id : null,
                            fg: fg,
                          ),
                          const SizedBox(width: Space.s),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  fixture.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: fg,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text.rich(
                                  TextSpan(
                                    children: <InlineSpan>[
                                      TextSpan(text: '$type · '),
                                      if (status == null) ...<InlineSpan>[
                                        WidgetSpan(
                                          alignment:
                                              PlaceholderAlignment.middle,
                                          child: Icon(
                                            Icons.wb_sunny_rounded,
                                            size: 12,
                                            color: small.color,
                                          ),
                                        ),
                                        TextSpan(text: ' $percent %'),
                                      ] else
                                        TextSpan(text: status),
                                    ],
                                  ),
                                  key: ValueKey<String>('row-subtitle-$id'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: small.copyWith(
                                    fontFeatures: const <FontFeature>[
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          AnimatedRotation(
                            turns: open ? 0.5 : 0,
                            duration: Motion.reduced(context)
                                ? Duration.zero
                                : Motion.fast,
                            child: Icon(
                              Icons.expand_more_rounded,
                              size: 18,
                              color: small.color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Space.xxs),
            Semantics(
              label: l.groupIncludeLight(fixture.name),
              child: Switch.adaptive(
                key: ValueKey<String>('include-$id'),
                value: following,
                onChanged: (bool v) => v
                    ? group.rejoin(id)
                    : group.setExcluded(id, excluded: true),
              ),
            ),
          ],
        ),
        GrowUnlessReduced(
          reduced: Motion.reduced(context),
          child: !open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: Space.xs),
                  child: Row(
                    children: <Widget>[
                      Expanded(child: _trim(l, small, g.trim)),
                      const SizedBox(width: Space.xs),
                      TextButton.icon(
                        key: ValueKey<String>('flash-$id'),
                        style: TextButton.styleFrom(
                          foregroundColor: fg,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.xs,
                          ),
                        ),
                        onPressed: ready && session != null
                            ? () => unawaited(session.identify())
                            : null,
                        icon: const Icon(Icons.flare_rounded, size: 18),
                        label: Text(
                          l.groupFlash,
                          semanticsLabel: l.groupIdentify(fixture.name),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// The light's level in the group, live while dragging (it moves that
  /// light alone; the release saves it).
  Widget _trim(AppLocalizations l, TextStyle small, double trim) => GlassSlider(
    key: ValueKey<String>('trim-${fixture.id}'),
    value: trim,
    min: GroupSession.minTrim,
    height: 36,
    elevated: false,
    semanticLabel: l.levelInGroupFor(fixture.name),
    valueText: _percent,
    leadingBuilder: (double v, double width) =>
        Text(l.levelInGroup, style: small.copyWith(color: fg)),
    trailingBuilder: (double v, double width) => Text(
      _percent(v),
      style: small.copyWith(
        color: fg,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    ),
    onChangeStart: (_) => group.beginTrim(fixture.id),
    onChanged: (double v) => group.setTrim(fixture.id, v, live: true),
    onChangeEnd: (double v) {
      group.setTrim(fixture.id, v);
      group.endTrim(fixture.id);
    },
  );
}

/// A row's light as a small still dot in its steady colour (dim while it
/// is off); neutral grey while it is not connected ([id] null).
class _LightDot extends ConsumerWidget {
  const _LightDot({required this.id, required this.fg, super.key});
  final String? id;
  final Color fg;

  static const double _size = 28;

  /// Not connected: a neutral grey, readable in both themes.
  static const Color _grey = Color(0xFF8E8E8E);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? id = this.id;
    final ({Color? colour, bool on}) s = id == null
        ? (colour: null, on: false)
        : _lightSwatch(ref, id);
    final Color? colour = s.colour;
    return Opacity(
      opacity: colour == null || s.on ? 1 : 0.35,
      child: Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colour ?? _grey,
          border: Border.all(color: fg.withValues(alpha: 0.14), width: 0.5),
        ),
      ),
    );
  }
}
