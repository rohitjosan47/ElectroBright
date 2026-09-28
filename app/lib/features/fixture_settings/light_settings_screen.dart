import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/color/light_tone.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/fixture.dart';
import '../../core/model/light_capabilities.dart';
import '../../core/protocol/eb/eb_scene.dart';
import '../../core/protocol/eb/mode_catalog.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/components/name_dialog.dart';
import '../../design/components/settings_list.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/rituals.dart';
import '../control/effects/mode_presentation.dart';
import '../control/presets/preset_meta.dart';
import '../developer/developer_tools.dart';
import '../developer/light_developer_screen.dart';
import '../firmware_update/update_firmware_screen.dart';
import '../firmware_update/update_providers.dart';
import '../../core/firmware/firmware_bundle.dart';

/// One light's settings: name, type and what it can do, identify / channel
/// test, sound, factory reset and forget.
class LightSettingsScreen extends ConsumerStatefulWidget {
  const LightSettingsScreen({required this.fixtureId, super.key});
  final String fixtureId;

  @override
  ConsumerState<LightSettingsScreen> createState() =>
      _LightSettingsScreenState();
}

class _LightSettingsScreenState extends ConsumerState<LightSettingsScreen> {
  Want? _want;

  /// Wire index of the LED lit by a running channel test.
  int? _testing;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final AppSession? app = ref.read(appSessionProvider);
    if (app?.ble.connections.session(widget.fixtureId) != null) {
      _want = app!.ble.connections.want(widget.fixtureId, WantReason.screen);
    }
  }

  @override
  void dispose() {
    _want?.release();
    super.dispose();
  }

  AppSession get _app => ref.read(appSessionProvider)!;

  void _update(Fixture f) => _app.registry.update(f);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture? f = ref.watch(fixtureProvider(widget.fixtureId));
    if (f == null) return const Scaffold();
    // Only what the screen shows.
    final (bool isReady, EbDeviceState? state) = ref.watch(
      fixtureStatusProvider(widget.fixtureId)
          .select((FixtureStatus s) => (s.isReady, s.state)),
    );
    final LightCapabilities caps =
        ref.watch(capabilitiesProvider(widget.fixtureId)) ??
        LightCapabilities.assumed(f.layout);
    final FixtureSession? session = ref.watch(
      fixtureSessionProvider(widget.fixtureId),
    );
    final bool ready = isReady && session != null;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final EbScene? scene = state?.scene;
    final LightTone tone = scene == null
        ? LightTone.neutral(dark: dark)
        : LightTone.derive(
            DisplayColor.ofScene(
              scene,
              sleeping: state!.sleeping,
              whitePoints: f.whitePoints,
              steady: ref.watch(steadyLevelsProvider(widget.fixtureId)),
            ),
            dark: dark,
          );
    final Color fg = settingsInk(context);
    final TextStyle title = settingsTitleStyle(context);
    final TextStyle sub = settingsDetailStyle(context);
    final bool developer = ref.watch(developerToolsProvider);
    final Widget? firmware = _firmwareRow(l, fg, title, sub);

    Widget section(String? heading, List<Widget> rows) =>
        SettingsSection(heading: heading, children: rows);

    Widget row(
      String label, {
      Key? key,
      String? detail,
      Widget? trailing,
      VoidCallback? onTap,
      Color? color,
    }) => ListTile(
      key: key,
      title: Text(label, style: title.copyWith(color: color)),
      subtitle: detail == null ? null : Text(detail, style: sub),
      trailing: trailing,
      enabled: onTap != null || trailing != null,
      onTap: onTap,
    );

    return ToneScope(
      tone: tone,
      child: SettingsPage(
        title: l.lightSettings,
        children: <Widget>[
          section(null, <Widget>[
            row(
              l.name,
              key: const ValueKey<String>('settings-name'),
              detail: f.name,
              trailing: Icon(Icons.edit_rounded, color: fg, size: 20),
              onTap: () async {
                final String? n = await showNameDialog(
                  context,
                  title: l.rename,
                  current: f.name,
                );
                if (n != null && n.isNotEmpty) {
                  _update(f.copyWith(name: n));
                }
              },
            ),
            SwitchListTile(
              title: Text(l.favourite, style: title),
              subtitle: Text(l.favouriteHint, style: sub),
              value: f.favourite,
              onChanged: (bool v) => _update(f.copyWith(favourite: v)),
            ),
          ]),
          section(l.type, <Widget>[
            ListTile(
              title: FixtureTypeBadge(
                layout: f.layout,
                whitePoints: f.whitePoints,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: Space.xxs),
                child: Text(fixtureTypeDescription(l, f.layout), style: sub),
              ),
            ),
            row(
              l.whatItCanDo,
              key: const ValueKey<String>('settings-caps'),
              trailing: Icon(Icons.chevron_right_rounded, color: fg),
              onTap: () => unawaited(
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (BuildContext ctx) =>
                      CapabilitySheet(fixture: f, capabilities: caps),
                ),
              ),
            ),
          ]),
          section(l.tools, <Widget>[
            row(
              l.identify,
              key: const ValueKey<String>('settings-identify'),
              detail: l.identifyHint,
              onTap: ready && !_busy
                  ? () => unawaited(_run(session.identify))
                  : null,
            ),
            row(
              l.channelTest,
              key: const ValueKey<String>('settings-channel-test'),
              detail: _testing != null
                  ? l.channelTestRunning(
                      channelName(l, f.layout.roles[_testing!]),
                    )
                  : l.channelTestHint,
              trailing: _testing != null
                  ? Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ledColor(
                          f.layout.roles[_testing!],
                          f.whitePoints,
                        ),
                      ),
                    )
                  : null,
              onTap: ready && !_busy
                  ? () => unawaited(
                      _run(
                        () => session.channelTest(
                          onChannel: (int? c) {
                            if (mounted) setState(() => _testing = c);
                          },
                        ),
                      ),
                    )
                  : null,
            ),
            SwitchListTile(
              key: const ValueKey<String>('settings-sound'),
              title: Text(l.sound, style: title),
              value: state?.soundOn ?? false,
              onChanged: ready
                  ? (bool on) => unawaited(session.setSound(on: on))
                  : null,
            ),
          ]),
          if (firmware != null) section(l.firmware, <Widget>[firmware]),
          if (developer)
            section(null, <Widget>[
              row(
                l.developer,
                key: const ValueKey<String>('light-settings-developer'),
                trailing: Icon(Icons.chevron_right_rounded, color: fg),
                onTap: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          LightDeveloperScreen(fixtureId: widget.fixtureId),
                    ),
                  ),
                ),
              ),
            ]),
          section(null, <Widget>[
            row(
              l.factoryReset,
              key: const ValueKey<String>('settings-reset'),
              color: const Color(0xFFE5484D),
              onTap: ready && !_busy
                  ? () => unawaited(_factoryReset(f, session))
                  : null,
            ),
            row(
              l.forgetLight,
              key: const ValueKey<String>('settings-forget'),
              color: const Color(0xFFE5484D),
              onTap: () => unawaited(_forget(f)),
            ),
          ]),
        ],
      ),
    );
  }

  /// "Update firmware" when the connected light's firmware is older than the
  /// app's: open for a light that updates wirelessly (or is updating), a note
  /// for one whose firmware can't. Null when there is nothing to offer.
  Widget? _firmwareRow(
    AppLocalizations l,
    Color fg,
    TextStyle title,
    TextStyle sub,
  ) {
    final (bool connected, String? version, bool wireless, bool updating) = ref
        .watch(
          fixtureStatusProvider(widget.fixtureId).select(
            (FixtureStatus s) => (
              s.isConnected,
              s.view?.firmware?.version.version,
              s.view?.firmware?.wirelessUpdates ?? false,
              s.updating,
            ),
          ),
        );
    final FirmwareVersion? bundled = ref.watch(
      bundledFirmwareProvider.select((FirmwareBundle? b) => b?.version),
    );
    final FirmwareVersion? installed = FirmwareVersion.tryParse(version);
    final bool older =
        connected &&
        bundled != null &&
        installed != null &&
        installed < bundled;
    if (!updating && !older) return null;
    void open() => unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UpdateFirmwareScreen(fixtureId: widget.fixtureId),
        ),
      ),
    );
    return ListTile(
      key: const ValueKey<String>('settings-update-firmware'),
      title: Text(l.updateFirmware, style: title),
      subtitle: Text(
        updating
            ? l.presenceUpdating
            : wireless
            ? l.updateAvailableDetail('$bundled', '$installed')
            : l.updateNeedsUsb('$installed'),
        style: sub,
      ),
      trailing: updating || wireless
          ? Icon(Icons.chevron_right_rounded, color: fg)
          : null,
      enabled: updating || wireless,
      onTap: updating || wireless ? open : null,
    );
  }

  Future<void> _factoryReset(Fixture f, FixtureSession s) async {
    final AppLocalizations l = AppLocalizations.of(context);
    final EbScene look = EbScene.defaults(f.layout);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l.factoryReset),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l.factoryResetConfirm),
            const SizedBox(height: Space.s),
            Row(
              children: <Widget>[
                Text('${l.factoryLook}: '),
                ChannelDots(
                  layout: f.layout,
                  color: look.color,
                  whitePoints: f.whitePoints,
                  size: 12,
                ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.erase),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      final EbResult r = await s.factoryReset();
      if (!mounted) return;
      if (r.isSuccess) {
        // The light has no presets any more.
        ref.read(presetMetaProvider(f.id).notifier).clearAll();
        HapticsScope.of(context).play(HapticEvent.success);
      } else {
        showGlassToast(
          context,
          r.outcome == EbOutcome.disconnected ? l.errorOffline : l.errorGeneric,
          icon: Icons.error_outline_rounded,
        );
      }
    });
  }

  Future<void> _forget(Fixture f) async {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l.forgetLight),
        content: Text(l.forgetConfirm(f.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.forget),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _want?.release();
    _want = null;
    // Back to Home before the light disappears from under the screens.
    Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    await _app.registry.forget(f.id);
  }
}

/// Everything the light's firmware says it can do.
class CapabilitySheet extends StatelessWidget {
  const CapabilitySheet({
    required this.fixture,
    required this.capabilities,
    super.key,
  });
  final Fixture fixture;
  final LightCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final FixtureIdentity? id = fixture.identity;
    final bool learned = id != null && !id.assumed;
    final List<String> missing = <String>[
      for (final EbModeSpec m in EbModeCatalog.modes)
        if (!capabilities.supportsMode(m.id)) m.name,
    ];
    final int supported = capabilities.modes.length;
    Widget item(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(k, style: theme.textTheme.bodyMedium),
          ),
          Expanded(child: v),
        ],
      ),
    );
    Text value(String s) => Text(
      s,
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          0,
          Space.gutter,
          Space.gutter,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l.whatItCanDo, style: theme.textTheme.titleLarge),
            const SizedBox(height: Space.xs),
            FixtureTypeBadge(
              layout: fixture.layout,
              whitePoints: fixture.whitePoints,
            ),
            const SizedBox(height: Space.s),
            item(
              l.capChannels,
              Wrap(
                spacing: Space.s,
                runSpacing: Space.xxs,
                children: <Widget>[
                  for (final ChannelRole r in fixture.layout.roles)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: ledColor(r, fixture.whitePoints),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.xxs),
                        value(channelName(l, r)),
                      ],
                    ),
                ],
              ),
            ),
            item(
              l.capEffects,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  value(l.capEffectsCount(supported, capabilities.modeCount)),
                  if (missing.isNotEmpty)
                    Text(
                      capabilities.layout == ChannelLayout.w &&
                              missing.length == 1 &&
                              !capabilities.supportsMode(10)
                          ? l.modeUnavailableRainbow
                          : l.capMissing(missing.join(', ')),
                      style: theme.textTheme.bodySmall,
                    ),
                  if (!fixture.layout.hasColour)
                    Text(
                      [
                        for (final EbModeSpec m in EbModeCatalog.modes)
                          if (capabilities.supportsMode(m.id))
                            presentMode(
                              m,
                              fixture.layout,
                              fixture.whitePoints,
                              l,
                            ).name,
                      ].join(', '),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            item(
              l.capPresets,
              value(l.capPresetsCount(capabilities.presetSlots)),
            ),
            item(
              l.capTimerSound,
              value(
                capabilities.hasTimer && capabilities.hasSound ? l.capYes : '—',
              ),
            ),
            const Divider(height: Space.xl),
            if (!learned)
              Text(l.capNotLearned, style: theme.textTheme.bodyMedium)
            else ...<Widget>[
              item(l.model, value(id.model ?? '—')),
              item(l.version, value(id.firmwareVersion ?? '—')),
              if (id.caps != null)
                item(
                  l.capRaw,
                  GestureDetector(
                    onLongPress: () {
                      unawaited(
                        Clipboard.setData(ClipboardData(text: id.caps!)),
                      );
                      showGlassToast(
                        context,
                        l.copied,
                        icon: Icons.copy_rounded,
                      );
                    },
                    child: SelectableText(
                      id.caps!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
