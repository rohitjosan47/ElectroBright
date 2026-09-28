import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/model/fixture.dart';
import '../../design/canvas/ambient_canvas.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/components/name_dialog.dart';
import '../../design/gallery/gallery.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/fixture_registry.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/rituals.dart';
import '../add_fixture/add_light_screen.dart';
import '../groups/group_screen.dart';
import '../control/control_screen.dart';
import 'groups_card.dart';
import '../../sessions/group_capabilities.dart';
import '../../sessions/group_session.dart';
import 'light_tile.dart';
import '../developer/developer_screen.dart';
import '../developer/developer_tools.dart';
import '../developer/light_developer_screen.dart';
import '../diagnostics/ble_lab.dart';
import '../firmware_update/firmware_update_screen.dart';
import '../fixture_settings/light_settings_screen.dart';

/// Whether Home's settings sheet offers the developer tools (BLE diagnostics
/// lab, design gallery): debug builds only, never profile or release. Tests
/// may flip it. The gallery also opens with `--dart-define=EB_START=gallery`.
@visibleForTesting
bool debugShowDeveloperTools = kDebugMode;

/// Home: every saved light with its type and state, plus lights nearby that
/// are not added yet.
/// How long Home's Identify waits for a light to connect.
const Duration identifyConnectTimeout = Duration(seconds: 10);

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<NearbyLight> _nearby = const <NearbyLight>[];
  final Map<String, Want> _wants = <String, Want>{};

  /// Lights an Identify is connecting or flashing.
  final Set<String> _identifying = <String>{};
  StreamSubscription<LayoutChange>? _layoutSub;
  FixtureRegistry? _registry;

  /// Lights kept connected while Home is open: favourites plus the most
  /// recently used, at most three (so this phone never grabs every light).
  void _syncWants(AppSession app, List<Fixture> fixtures) {
    final List<Fixture> ordered = List<Fixture>.of(fixtures)
      ..sort((Fixture a, Fixture b) {
        if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
        final DateTime ta = a.lastConnectedAt ?? a.addedAt;
        final DateTime tb = b.lastConnectedAt ?? b.addedAt;
        return tb.compareTo(ta);
      });
    final Set<String> keep = ordered.take(3).map((Fixture f) => f.id).toSet();
    for (final String id in _wants.keys.toList()) {
      if (!keep.contains(id)) _wants.remove(id)!.release();
    }
    for (final String id in keep) {
      _wants.putIfAbsent(
        id,
        () => app.ble.connections.want(id, WantReason.favourite),
      );
    }
  }

  void _watchLayoutChanges(AppSession app) {
    if (identical(_registry, app.registry)) return;
    _registry = app.registry;
    unawaited(_layoutSub?.cancel());
    _layoutSub = app.registry.layoutChanges.listen((LayoutChange c) {
      if (!mounted) return;
      final AppLocalizations l = AppLocalizations.of(context);
      showGlassToast(
        context,
        l.layoutChanged(c.after.name, fixtureTypeName(l, c.after.layout)),
        icon: Icons.info_outline_rounded,
      );
    });
  }

  @override
  void dispose() {
    for (final Want w in _wants.values) {
      w.release();
    }
    unawaited(_layoutSub?.cancel());
    super.dispose();
  }

  void _open(Fixture f) {
    final FixtureStatus st = ref.read(fixtureStatusProvider(f.id));
    // No fixture type yet: only setting it up (whether or not the developer
    // tools are on).
    if (f.setupNeeded || st.incompatibility == EbIncompatibility.setupNeeded) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LightDeveloperScreen(fixtureId: f.id),
          ),
        ),
      );
      return;
    }
    if (st.phase == LinkPhase.incompatible) {
      final AppSession app = ref.read(appSessionProvider)!;
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext ctx) => FirmwareUpdateScreen(
              name: f.name,
              incompatibility: st.incompatibility,
              detail: st.detail,
              onRetry: () {
                app.ble.connections.retry(f.id);
                Navigator.of(ctx).pop();
              },
              onForget: () {
                unawaited(app.registry.forget(f.id));
                Navigator.of(ctx).pop();
              },
            ),
          ),
        ),
      );
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ControlScreen(fixtureId: f.id)),
      ),
    );
  }

  /// A group (from its card): connects the group while it is open,
  /// releases it after.
  void _openGroup(GroupKind kind) => unawaited(
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => GroupScreen(kind: kind))),
  );

  Future<void> _more(Fixture f) async {
    final AppLocalizations l = AppLocalizations.of(context);
    final AppSession app = ref.read(appSessionProvider)!;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: Text(l.rename),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.flare_rounded),
              title: Text(l.identify),
              onTap: () => Navigator.of(ctx).pop('identify'),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: Text(l.lightSettings),
              onTap: () => Navigator.of(ctx).pop('settings'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(l.forgetLight),
              onTap: () => Navigator.of(ctx).pop('forget'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        final String? name = await _askName(f.name);
        if (name != null && name.isNotEmpty) {
          app.registry.update(f.copyWith(name: name));
        }
      case 'identify':
        await _identify(app, f);
      case 'settings':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LightSettingsScreen(fixtureId: f.id),
          ),
        );
      case 'forget':
        _wants.remove(f.id)?.release();
        await app.registry.forget(f.id);
    }
  }

  /// Identifies [f], connecting it first if needed ("Connecting…"; gives
  /// up after [identifyConnectTimeout]). A second tap while one runs does
  /// nothing.
  Future<void> _identify(AppSession app, Fixture f) async {
    if (!_identifying.add(f.id)) return;
    final Want w = app.ble.connections.want(f.id, WantReason.action);
    try {
      final FixtureSession? s = app.ble.connections.session(f.id);
      if (s == null) return;
      if (!s.status.isReady) {
        final AppLocalizations l = AppLocalizations.of(context);
        showGlassToast(context, l.presenceConnecting, icon: Icons.bluetooth);
        if (!await _readyWithin(s, identifyConnectTimeout)) {
          if (mounted) {
            showGlassToast(
              context,
              l.identifyUnreachable(f.name),
              icon: Icons.info_outline_rounded,
            );
          }
          return;
        }
      }
      await s.identify();
    } finally {
      w.release();
      _identifying.remove(f.id);
    }
  }

  /// Whether [s] is ready now or becomes ready within [limit].
  static Future<bool> _readyWithin(FixtureSession s, Duration limit) async {
    final Completer<bool> done = Completer<bool>();
    final StreamSubscription<FixtureStatus> sub = s.statuses.listen((
      FixtureStatus st,
    ) {
      if (st.isReady && !done.isCompleted) done.complete(true);
    });
    final Timer timer = Timer(limit, () {
      if (!done.isCompleted) done.complete(false);
    });
    if (s.status.isReady && !done.isCompleted) done.complete(true);
    final bool ready = await done.future;
    timer.cancel();
    unawaited(sub.cancel());
    return ready;
  }

  /// A titled list of nearby lights (not added, or unsupported); a row
  /// opens the add flow, which sends a legacy light to its firmware update.
  Widget _nearbySection(
    Color fg,
    String title,
    List<NearbyLight> lights, {
    String? note,
    double top = 0,
  }) => SliverPadding(
    padding: EdgeInsets.fromLTRB(Space.gutter, top, Space.gutter, 0),
    sliver: SliverList.list(
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            title,
            style: TextStyle(
              color: fg,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(note, style: TextStyle(color: fg.withValues(alpha: 0.65))),
        ],
        const SizedBox(height: Space.s),
        for (final NearbyLight n in lights)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: NearbyRow(
              light: n,
              onTap: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<String>(
                    builder: (_) => AddLightScreen(initial: n),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Future<String?> _askName(String current) => showNameDialog(
    context,
    title: AppLocalizations.of(context).rename,
    current: current,
  );

  Future<void> _settings() async {
    final AppLocalizations l = AppLocalizations.of(context);
    final AppSession app = ref.read(appSessionProvider)!;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.swap_horiz_rounded),
              title: Text(app.demo ? l.switchToRealLights : l.switchToDemo),
              onTap: () => Navigator.of(ctx).pop('mode'),
            ),
            if (debugShowDeveloperTools) ...<Widget>[
              ListTile(
                key: const ValueKey<String>('settings-lab'),
                leading: const Icon(Icons.science_outlined),
                title: Text(l.diagnostics),
                onTap: () => Navigator.of(ctx).pop('lab'),
              ),
              ListTile(
                key: const ValueKey<String>('settings-gallery'),
                leading: const Icon(Icons.palette_outlined),
                title: Text(l.designGallery),
                onTap: () => Navigator.of(ctx).pop('gallery'),
              ),
            ],
            // Last: the switch for the developer tools and, when on, their
            // entry.
            Consumer(
              builder: (BuildContext ctx, WidgetRef ref, _) {
                final bool on = ref.watch(developerToolsProvider);
                final ThemeData theme = Theme.of(ctx);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.m,
                        Space.xs,
                        Space.m,
                        0,
                      ),
                      child: Semantics(
                        header: true,
                        child: Text(
                          l.advanced.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 0.4,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    SwitchListTile(
                      key: const ValueKey<String>('settings-developer-tools'),
                      secondary: const Icon(Icons.handyman_outlined),
                      title: Text(l.developerTools),
                      subtitle: Text(l.developerToolsHint),
                      value: on,
                      onChanged: (bool v) =>
                          ref.read(developerToolsProvider.notifier).set(on: v),
                    ),
                    if (on)
                      ListTile(
                        key: const ValueKey<String>('settings-developer'),
                        leading: const Icon(Icons.developer_mode_rounded),
                        title: Text(l.developer),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(ctx).pop('developer'),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'mode':
        await ref.read(appSessionProvider.notifier).start(demo: !app.demo);
      case 'lab':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const BleLabScreen()));
      case 'gallery':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ComponentGallery()),
        );
      case 'developer':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const DeveloperScreen()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final AppSession? app = ref.watch(appSessionProvider);
    final List<Fixture> fixtures = ref.watch(fixturesProvider);
    // The nearby list, and the fast scan behind it, only while Home is on
    // screen: covered by a full-screen route it keeps the last list.
    if (TickerMode.valuesOf(context).enabled) {
      _nearby = ref.watch(nearbyProvider);
    }
    // Lights on unsupported (legacy) firmware get their own section.
    final List<NearbyLight> nearby = <NearbyLight>[
      for (final NearbyLight n in _nearby)
        if (!n.isLegacy) n,
    ];
    final List<NearbyLight> unsupported = <NearbyLight>[
      for (final NearbyLight n in _nearby)
        if (n.isLegacy) n,
    ];
    if (app != null) {
      _syncWants(app, fixtures);
      _watchLayoutChanges(app);
    }
    final int connected = fixtures
        .where(
          (Fixture f) => ref.watch(
            fixtureStatusProvider(f.id)
                .select((FixtureStatus s) => s.phase == LinkPhase.ready),
          ),
        )
        .length;
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final bool bigText = MediaQuery.textScalerOf(context).scale(1) > 1.4;
    // Groups with 2 or more lights.
    final List<GroupKind> groups = <GroupKind>[
      if (app != null)
        for (final GroupKind k in GroupKind.values)
          if (ref.watch(
            groupStatusProvider(k).select((GroupStatus s) => s.exists),
          ))
            k,
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: app == null
            ? null
            : () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<String>(
                    builder: (_) => const AddLightScreen(),
                  ),
                ),
              ),
        icon: const Icon(Icons.add_rounded),
        label: Text(l.addLight),
      ),
      body: AmbientCanvas(
        child: CustomScrollView(
          slivers: <Widget>[
            SliverSafeArea(
              bottom: false,
              sliver: SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.l,
                  Space.gutter,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    l.lightsTitle,
                                    style: TextStyle(
                                      color: fg,
                                      fontSize: 34,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (app?.demo ?? false) ...<Widget>[
                                  const SizedBox(width: Space.xs),
                                  Chip(label: Text(l.demoBadge)),
                                ],
                              ],
                            ),
                            Text(
                              l.homeSummary(connected, nearby.length),
                              style: TextStyle(
                                color: fg.withValues(alpha: 0.65),
                              ),
                            ),
                          ],
                        ),
                      ),
                      GlassIconButton(
                        icon: Icons.tune_rounded,
                        label: l.settings,
                        onPressed: app == null
                            ? null
                            : () => unawaited(_settings()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (fixtures.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(Space.gutter),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    l.homeEmpty,
                    style: TextStyle(color: fg.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            if (groups.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.gutter,
                  Space.gutter,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: GroupsCard(kinds: groups, onOpen: _openGroup),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(Space.gutter),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: bigText ? 1 : 2,
                  mainAxisSpacing: Space.s,
                  crossAxisSpacing: Space.s,
                  mainAxisExtent: bigText ? 300 : 214,
                ),
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int i) => LightTile(
                    key: ValueKey<String>(fixtures[i].id),
                    fixtureId: fixtures[i].id,
                    onOpen: () => _open(fixtures[i]),
                    onMore: () => unawaited(_more(fixtures[i])),
                  ),
                  childCount: fixtures.length,
                ),
              ),
            ),
            if (nearby.isNotEmpty) _nearbySection(fg, l.nearbyTitle, nearby),
            // Older firmware the app can't drive: last, apart from the rest.
            if (unsupported.isNotEmpty)
              _nearbySection(
                fg,
                l.unsupportedTitle,
                unsupported,
                note: l.unsupportedNote,
                top: nearby.isEmpty ? 0 : Space.l,
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}
