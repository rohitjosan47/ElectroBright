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
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<NearbyLight> _nearby = const <NearbyLight>[];
  final Map<String, Want> _wants = <String, Want>{};
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
        final Want w = app.ble.connections.want(f.id, WantReason.action);
        final FixtureSession? s = app.ble.connections.session(f.id);
        final FixtureStatus ready = await s!.statuses
            .firstWhere((FixtureStatus x) => x.isReady)
            .timeout(const Duration(seconds: 10), onTimeout: () => s.status);
        if (ready.isReady) await s.identify();
        w.release();
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
    final List<NearbyLight> nearby = _nearby;
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
            if (nearby.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                sliver: SliverList.list(
                  children: <Widget>[
                    Text(
                      l.nearbyTitle,
                      style: TextStyle(
                        color: fg,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Space.s),
                    for (final NearbyLight n in nearby)
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
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}
