import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/bluetooth_access.dart';
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
import 'bluetooth_notice.dart';
import 'light_tile.dart';
import 'updates_banner.dart';
import '../developer/developer_screen.dart';
import '../developer/developer_tools.dart';
import '../developer/light_developer_screen.dart';
import '../diagnostics/ble_lab.dart';
import '../firmware_update/firmware_update_screen.dart';
import '../firmware_update/update_firmware_screen.dart';
import '../firmware_update/update_providers.dart';
import '../fixture_settings/light_settings_screen.dart';

/// Whether Home's settings sheet offers the developer tools (BLE diagnostics
/// lab, design gallery): debug builds only, never profile or release. Tests
/// may flip it. The gallery also opens with `--dart-define=EB_START=gallery`.
@visibleForTesting
bool debugShowDeveloperTools = kDebugMode;

/// Home: every saved light with its type and state. Lights nearby that can
/// be added show as a count on "Add light"; the add screen lists them.

/// How long Home's Identify waits for a light to connect.
const Duration identifyConnectTimeout = Duration(seconds: 10);

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Lights nearby that can be added (the "Add light" badge).
  int _nearby = 0;
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
    // Being updated: its progress.
    if (st.updating) return _openUpdate(f.id);
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

  /// A light's firmware update (its tile badge, the banner, a tap while it
  /// updates).
  void _openUpdate(String id) => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpdateFirmwareScreen(fixtureId: id),
      ),
    ),
  );

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
        final AppController c = ref.read(appSessionProvider.notifier);
        await (app.demo ? c.useMyLights() : c.start(demo: true));
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
    // The badge, and the low-power scan behind it, only while Home is on
    // screen: covered by a full-screen route it keeps the last count.
    if (TickerMode.valuesOf(context).enabled) {
      _nearby = ref.watch(nearbyBadgeProvider);
    }
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
    final List<String> updates = ref.watch(lightsWithUpdateProvider);
    final bool bluetoothIssue = ref.watch(bluetoothIssueProvider) != null;
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
      // The count of lights nearby that can be added, on the button's
      // corner. Brand colour, not the error red: nothing is wrong.
      floatingActionButton: Badge(
        isLabelVisible: _nearby > 0,
        backgroundColor: Theme.of(context).colorScheme.primary,
        textColor: Theme.of(context).colorScheme.onPrimary,
        label: ExcludeSemantics(child: Text('$_nearby')),
        child: FloatingActionButton.extended(
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
          label: Text(
            l.addLight,
            semanticsLabel: _nearby > 0 ? l.addLightNearby(_nearby) : null,
          ),
        ),
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
                              l.homeSummary(connected, fixtures.length),
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
            if (bluetoothIssue)
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.s,
                  Space.gutter,
                  0,
                ),
                sliver: SliverToBoxAdapter(child: BluetoothNotice()),
              ),
            if (updates.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.s,
                  Space.gutter,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: UpdatesBanner(
                    count: updates.length,
                    onTap: () => _openUpdate(updates.first),
                  ),
                ),
              ),
            if (fixtures.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(Space.gutter),
                sliver: SliverToBoxAdapter(child: _Welcome(fg: fg)),
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
                    onUpdate: () => _openUpdate(fixtures[i].id),
                  ),
                  childCount: fixtures.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}

/// No saved lights yet: a short welcome pointing to "Add light".
class _Welcome extends StatelessWidget {
  const _Welcome({required this.fg});
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            l.homeWelcomeTitle,
            style: TextStyle(
              color: fg,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          l.homeWelcomeBody,
          style: TextStyle(color: fg.withValues(alpha: 0.7)),
        ),
      ],
    );
  }
}
