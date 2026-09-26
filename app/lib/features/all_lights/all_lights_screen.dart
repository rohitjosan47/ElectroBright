import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/color/colour_engine.dart';
import '../../core/color/led_white_points.dart';
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
import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/group_session.dart';
import '../../sessions/rituals.dart';
import '../control/colour/colour_editor.dart';
import '../control/effects/effects_grid.dart';
import '../control/effects/mode_presentation.dart';
import '../control/shared/brightness_pill_slider.dart';
import '../control/shared/control_header.dart';
import '../control/shared/tab_switcher.dart';
import '../control/timer_sheet.dart';
import '../home/presence.dart';

enum _GroupTab { colour, effects }

/// Sends a group command and says how it went (one message per command).
typedef _Run = void Function(Future<GroupResult> command);

/// All Lights: the same settings sent at the same moment to every light in
/// the group (each light keeps its own effect clock).
class AllLightsScreen extends ConsumerStatefulWidget {
  const AllLightsScreen({super.key});

  @override
  ConsumerState<AllLightsScreen> createState() => _AllLightsScreenState();
}

class _AllLightsScreenState extends ConsumerState<AllLightsScreen> {
  GroupSession? _group;
  _GroupTab _tab = _GroupTab.colour;

  @override
  void initState() {
    super.initState();
    _group = ref.read(groupSessionProvider)?..activate();
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
    final bool anyOn = ref.watch(groupAnyOnProvider);
    final bool live = ref.watch(
      groupStatusProvider.select((GroupStatus s) => s.ready > 0),
    );
    return _GroupTone(
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
                title: l.allLightsTitle,
                subtitle: Text(
                  l.allLightsSubtitle,
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
              const Center(child: RepaintBoundary(child: _GroupOrb())),
              const SizedBox(height: Space.s),
              _StatusLine(budget: group.budget, fg: fg),
              const SizedBox(height: Space.s),
              _GroupToolbar(group: group, enabled: live && anyOn, run: _run),
              const SizedBox(height: Space.m),
              RepaintBoundary(
                child: _GroupBrightness(group: group, enabled: live, fg: fg),
              ),
              const SizedBox(height: Space.m),
              GlassSegmented<_GroupTab>(
                segments: <(_GroupTab, String)>[
                  (_GroupTab.colour, l.tabColour),
                  (_GroupTab.effects, l.tabEffects),
                ],
                selected: _tab,
                thumbTier: GlassTier.chrome,
                onChanged: (_GroupTab t) => setState(() => _tab = t),
              ),
              const SizedBox(height: Space.m),
              TabSwitcher(
                index: _tab.index,
                child: KeyedSubtree(
                  key: ValueKey<_GroupTab>(_tab),
                  child: RepaintBoundary(
                    child: switch (_tab) {
                      _GroupTab.colour => _GroupColourTab(
                        group: group,
                        enabled: live,
                      ),
                      _GroupTab.effects => _GroupEffectsTab(
                        group: group,
                        enabled: live,
                        fg: fg,
                        run: _run,
                      ),
                    },
                  ),
                ),
              ),
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
  const _GroupTone({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ChannelColor colour = ref.watch(
      groupColourProvider.select(_groupColour),
    );
    final int mode = ref.watch(
      groupModeProvider.select(
        (Common<int> m) => m.value ?? EbModeCatalog.solid,
      ),
    );
    final bool anyOn = ref.watch(groupAnyOnProvider);
    return ToneScope(
      tone: LightTone.derive(
        DisplayColor.ofScene(
          EbScene.defaults(ChannelLayout.rgbcct)
              .copyWith(color: colour, mode: mode, brightness: 255),
          sleeping: !anyOn,
        ),
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
      child: child,
    );
  }
}

/// What the group's colour controls and tiles start from: the lights'
/// common colour as an RGB+CCT light makes it, else a neutral white.
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

/// Up to four connected lights as small still orbs, fanned out, and how
/// many more there are.
class _GroupOrb extends ConsumerWidget {
  const _GroupOrb();

  static const int _shown = 4;
  static const double _size = 64;
  static const double _step = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GroupStatus st = ref.watch(groupStatusProvider);
    final List<String> ready = <String>[
      for (final GroupMember m in st.members)
        if (m.phase == LinkPhase.ready) m.id,
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

/// One light's colour as a still orb (dim while it is off).
class _MiniOrb extends ConsumerWidget {
  const _MiniOrb({required this.id});
  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? id = this.id;
    Color colour = const Color(0xFFFFF4E6);
    bool on = false;
    if (id != null) {
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
      if (c != null) {
        colour = swatchOf(c, wp, steady: ref.watch(steadyLevelsProvider(id)));
      }
      on = s.on;
    }
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
  const _StatusLine({required this.budget, required this.fg});
  final int budget;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupStatus st = ref.watch(groupStatusProvider);
    // Out of every saved light: one left out of the group is not connected
    // for it.
    final int saved = ref.watch(
      fixturesProvider.select((List<Fixture> l) => l.length),
    );
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
            <String>[
              l.groupConnected(st.ready, saved),
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
  final _Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool differ = ref.watch(
      groupTimerProvider.select((Common<Duration> c) => c.mixed),
    );
    Future<String?> send(int seconds) async {
      final GroupResult r = await group.setTimer(seconds);
      if (r.failed > 0) return l.errorGeneric;
      if (r.skipped > 0) run(Future<GroupResult>.value(r));
      return null;
    }

    return TimerCountdown(
      deadline: groupTimerDeadlineProvider,
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
                      deadline: groupTimerDeadlineProvider,
                      spanKey: GroupSession.timerSpanKey,
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

/// The lights' common brightness, or "Mixed" until a drag sets them all.
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
    final Common<int> b = ref.watch(groupBrightnessProvider);
    final bool anyOn = ref.watch(groupAnyOnProvider);
    return BrightnessPillSlider(
      // Mixed: the fill rests half way (no light's value).
      value: b.mixed ? 0.5 : (anyOn ? (b.value ?? 0) / 255 : 0),
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

/// The colour for every light, picked as on an RGB+CCT light (colour wheel
/// or white): each light makes it as well as it can.
class _GroupColourTab extends ConsumerWidget {
  const _GroupColourTab({required this.group, required this.enabled});
  final GroupSession group;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ChannelColor value = ref.watch(
      groupColourProvider.select(_groupColour),
    );
    return GlassSurface(
      padding: const EdgeInsets.all(Space.m),
      child: ColourEditor(
        value: value,
        showChannels: false,
        enabled: enabled,
        onGestureStart: () => group.beginGesture(EbKeys.color),
        onGestureEnd: () => group.endGesture(EbKeys.color),
        onChanged: (
          ChannelColor c, {
          required bool live,
          ColourIntent? intent,
        }) => unawaited(group.setColour(intent ?? RawIntent(c), live: live)),
      ),
    );
  }
}

/// What the effects tab reads of one ready light.
typedef _LightMode = ({
  int mode,
  int speed,
  int frequency,
  LightCapabilities? caps,
});

/// Every effect at least one connected light has; "3/5" on those only some
/// have. An effect is lit when every light that has it runs it.
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
  final _Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<String> ready = <String>[
      for (final GroupMember m in ref.watch(groupStatusProvider).members)
        if (m.phase == LinkPhase.ready) m.id,
    ];
    final List<_LightMode> lights = <_LightMode>[
      for (final String id in ready)
        ref.watch(
          fixtureStatusProvider(id).select((FixtureStatus s) {
            final int mode = s.state?.scene.mode ?? EbModeCatalog.solid;
            return (
              mode: mode,
              speed: s.state?.scene.speeds[mode - 1] ?? 5,
              frequency: s.state?.scene.frequencies[mode - 1] ?? 5,
              caps: s.view?.firmware?.capabilities,
            );
          }),
        ),
    ];
    final List<LightCapabilities> caps = <LightCapabilities>[
      for (int i = 0; i < ready.length; i++)
        lights[i].caps ??
            ref.watch(fixtureProvider(ready[i]))?.capabilities ??
            LightCapabilities.assumed(ChannelLayout.rgbcct),
    ];
    final List<EbModeSpec> modes = <EbModeSpec>[
      for (final EbModeSpec m in presentModes(
        const LightCapabilities(layout: ChannelLayout.rgbcct),
        const LedWhitePoints(),
        l,
      ))
        if (caps.any((LightCapabilities c) => c.supportsMode(m.id))) m,
    ];
    List<int> having(int mode) => <int>[
      for (int i = 0; i < ready.length; i++)
        if (caps[i].supportsMode(mode)) i,
    ];
    final Map<int, String> badges = <int, String>{
      for (final EbModeSpec m in modes)
        if (having(m.id).length < ready.length)
          m.id: '${having(m.id).length}/${ready.length}',
    };
    final EbModeSpec? selected = modes
        .where(
          (EbModeSpec m) =>
              having(m.id).every((int i) => lights[i].mode == m.id),
        )
        .firstOrNull;
    final int? first = selected == null
        ? null
        : having(selected.id).firstOrNull;
    final Color colour = swatchOf(
      ref.watch(groupColourProvider.select(_groupColour)),
      const LedWhitePoints(),
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
          animate: enabled && ref.watch(groupAnyOnProvider),
          onSelect: (int mode) {
            if (enabled) run(group.setMode(mode));
          },
        ),
        ModeSettingsSwitcher(
          mode:
              selected != null &&
                  first != null &&
                  (selected.hasSpeed || selected.hasFrequency)
              ? selected
              : null,
          builder: (EbModeSpec mode) => ModeSliders(
            mode: mode,
            speed: lights[first!].speed,
            frequency: lights[first].frequency,
            enabled: enabled,
            fg: fg,
            onSpeed: (int v) => run(group.setSpeed(mode.id, v)),
            onFrequency: (int v) => run(group.setFrequency(mode.id, v)),
          ),
        ),
      ],
    );
  }
}

/// Every saved light: its type, name, connection, Identify and whether it
/// is in the group.
class _GroupLights extends ConsumerWidget {
  const _GroupLights({required this.group, required this.fg});
  final GroupSession group;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<Fixture> fixtures = ref.watch(fixturesProvider);
    return GlassSurface(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            l.groupLights,
            style: TextStyle(
              color: fg,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final Fixture f in fixtures)
            Padding(
              padding: const EdgeInsets.only(top: Space.s),
              child: _GroupLightRow(
                key: ValueKey<String>('group-light-${f.id}'),
                fixture: f,
                group: group,
                fg: fg,
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupLightRow extends ConsumerWidget {
  const _GroupLightRow({
    required this.fixture,
    required this.group,
    required this.fg,
    super.key,
  });
  final Fixture fixture;
  final GroupSession group;
  final Color fg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final String id = fixture.id;
    final (LinkPhase, EbIncompatibility?) p = ref.watch(
      fixtureStatusProvider(id)
          .select((FixtureStatus s) => (s.phase, s.incompatibility)),
    );
    final bool included = ref.watch(
      groupStatusProvider.select(
        (GroupStatus s) => s.members.any((GroupMember m) => m.id == id),
      ),
    );
    final FixtureSession? session = ref.watch(fixtureSessionProvider(id));
    final bool ready = p.$1 == LinkPhase.ready;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FixtureTypeBadge(
                layout: fixture.layout,
                whitePoints: fixture.whitePoints,
              ),
              const SizedBox(height: Space.xxs),
              Text(
                fixture.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
              Text(
                presenceOf(l, p.$1, p.$2),
                style: TextStyle(
                  color: fg.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        GlassIconButton(
          key: ValueKey<String>('identify-$id'),
          icon: Icons.flare_rounded,
          label: l.groupIdentify(fixture.name),
          size: 36,
          tier: GlassTier.panel,
          onPressed: ready && session != null
              ? () => unawaited(session.identify())
              : null,
        ),
        const SizedBox(width: Space.s),
        Semantics(
          label: l.groupIncludeLight(fixture.name),
          child: Switch.adaptive(
            key: ValueKey<String>('include-$id'),
            value: included,
            onChanged: (bool v) => group.setExcluded(id, excluded: !v),
          ),
        ),
      ],
    );
  }
}
