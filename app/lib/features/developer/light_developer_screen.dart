import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/bluetooth_access.dart';
import '../../app/providers.dart';
import '../../core/color/led_white_points.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/fixture.dart';
import '../../core/protocol/eb/eb_reply.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/components/settings_list.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../drivers/electrobright/eb_session.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/firmware_update.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/group_capabilities.dart';
import '../../core/firmware/firmware_bundle.dart';
import '../control/presets/preset_meta.dart';
import '../firmware_update/update_firmware_screen.dart';
import '../firmware_update/update_providers.dart';
import '../home/presence.dart';
import 'diag_report.dart';
import 'fixture_probe.dart';
import 'probe_sheet.dart';
import 'rollback_test.dart';

/// How long a type change waits for the light to come back as its new type.
const Duration typeChangeReconnectLimit = Duration(seconds: 30);

enum _Change { sending, restarting, done, failed, notBack }

/// One light's developer page: its fixture type (with the probe test and a
/// type change), firmware version and diagnostics. A light in setup-needed
/// mode gets only the probe test and the type list. Keeps the light
/// connected ([WantReason.setup]) while open.
class LightDeveloperScreen extends ConsumerStatefulWidget {
  const LightDeveloperScreen({required this.fixtureId, super.key});
  final String fixtureId;

  @override
  ConsumerState<LightDeveloperScreen> createState() =>
      _LightDeveloperScreenState();
}

class _LightDeveloperScreenState extends ConsumerState<LightDeveloperScreen> {
  Want? _want;
  ChannelLayout? _selected;
  ChannelLayout? _suggested;
  _Change? _change;
  ChannelLayout? _target;
  DiagReport? _diag;
  bool _diagBusy = false;
  bool _diagFailed = false;
  bool _diagAsked = false;

  @override
  void initState() {
    super.initState();
    final AppSession? app = ref.read(appSessionProvider);
    if (app?.ble.connections.session(widget.fixtureId) != null) {
      _want = app!.ble.connections.want(widget.fixtureId, WantReason.setup);
    }
  }

  @override
  void dispose() {
    _want?.release();
    super.dispose();
  }

  FixtureSession? get _session =>
      ref.read(appSessionProvider)?.ble.connections.session(widget.fixtureId);

  Future<void> _readDiag() async {
    final FixtureSession? s = _session;
    if (s == null || _diagBusy) return;
    setState(() => _diagBusy = true);
    final Map<String, int>? values = await s.diag();
    if (!mounted) return;
    setState(() {
      _diagBusy = false;
      _diagFailed = values == null;
      if (values != null) _diag = DiagReport(values);
    });
  }

  Future<void> _probe() async {
    final FixtureSession? s = _session;
    if (s == null) return;
    final ChannelLayout? type = await showProbeSheet(context, s);
    if (!mounted || type == null) return;
    setState(() => _selected = _suggested = type);
  }

  Future<void> _changeType(Fixture f, ChannelLayout to) async {
    final AppLocalizations l = AppLocalizations.of(context);
    final String type = fixtureTypeName(l, to);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l.changeTypeTitle(type)),
        content: Text(
          l.changeTypeBody(f.name, type, switch (GroupKind.of(to)) {
            GroupKind.colour => l.groupColourTitle,
            GroupKind.white => l.groupWhiteTitle,
          }),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const ValueKey<String>('change-type-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.change),
          ),
        ],
      ),
    );
    final FixtureSession? s = _session;
    if (ok != true || !mounted || s == null) return;
    setState(() {
      _change = _Change.sending;
      _target = to;
    });
    final EbSession? link = s.session;
    final EbResult r = await s.setType(to);
    if (!mounted) return;
    // The link dropped before the reply: the light may have taken the type
    // (its OK lost to the restart) or not; its next handshake tells.
    final bool dropped = r.outcome == EbOutcome.disconnected;
    if (!r.isSuccess && !dropped) {
      setState(() => _change = _Change.failed);
      return;
    }
    setState(() => _change = _Change.restarting);
    final bool back = await _cameBackAs(
      s,
      to,
      droppedFrom: dropped ? link : null,
    );
    if (!mounted) return;
    if (dropped && !back && s.status.isReady) {
      // Back as it was: the type was not changed.
      setState(() => _change = _Change.failed);
      return;
    }
    // The light erased its presets: so do their names here.
    if (back || !dropped) {
      ref.read(presetMetaProvider(f.id).notifier).clearAll();
    }
    HapticsScope.of(context)
        .play(back ? HapticEvent.success : HapticEvent.selection);
    setState(() {
      _change = back ? _Change.done : _Change.notBack;
      _selected = _suggested = null;
      _diag = null;
      _diagAsked = false;
    });
  }

  /// Whether the light restarts and is identified as [to] (the registry
  /// re-identifies it) within [typeChangeReconnectLimit]. After a link
  /// that [droppedFrom] before SET_TYPE was answered, a light back on a new
  /// link as another type ends the wait at once (false).
  Future<bool> _cameBackAs(
    FixtureSession s,
    ChannelLayout to, {
    EbSession? droppedFrom,
  }) async {
    final AppSession app = ref.read(appSessionProvider)!;
    bool isBack() {
      final Fixture? f = app.registry.byId(widget.fixtureId);
      return s.status.isReady &&
          f != null &&
          f.layout == to &&
          !f.setupNeeded &&
          s.status.view?.firmware?.layout == to;
    }

    bool backAsOther() {
      final ChannelLayout? now = s.status.view?.firmware?.layout;
      return droppedFrom != null &&
          !identical(s.session, droppedFrom) &&
          s.status.isReady &&
          now != null &&
          now != to;
    }

    final Completer<bool> done = Completer<bool>();
    void check([Object? _]) {
      if (done.isCompleted) return;
      if (isBack()) {
        done.complete(true);
      } else if (backAsOther()) {
        done.complete(false);
      }
    }

    final StreamSubscription<FixtureStatus> a = s.statuses.listen(check);
    final StreamSubscription<List<Fixture>> b = app.registry.changes.listen(
      check,
    );
    check();
    final Timer limit = Timer(typeChangeReconnectLimit, () {
      if (!done.isCompleted) done.complete(false);
    });
    final bool back = await done.future;
    limit.cancel();
    unawaited(a.cancel());
    unawaited(b.cancel());
    return back;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture? f = ref.watch(fixtureProvider(widget.fixtureId));
    if (f == null) return const Scaffold();
    final FixtureStatus status = ref.watch(
      fixtureStatusProvider(widget.fixtureId),
    );
    final FixtureSession? session = ref.watch(
      fixtureSessionProvider(widget.fixtureId),
    );
    final bool inSetup = session?.inSetup ?? false;
    final bool setup =
        f.setupNeeded ||
        status.incompatibility == EbIncompatibility.setupNeeded;
    // What the light reported: live (typed or in setup-needed mode), else
    // saved from its last connection.
    final EbCaps? liveCaps =
        status.view?.firmware?.caps ??
        (inSetup ? session!.session?.setup?.caps : null);
    final bool connected = status.isReady || inSetup;
    final bool learned = f.identity != null && !f.identity!.assumed;
    final bool canType = liveCaps != null
        ? liveCaps.types.isNotEmpty
        : f.capabilities.supportsTypeChange;
    final bool canProbe = liveCaps != null
        ? liveCaps.probe
        : f.capabilities.supportsProbe;
    final String? version =
        status.view?.firmware?.version.version ??
        (inSetup ? session!.session?.setup?.version : null) ??
        f.identity?.firmwareVersion;
    final bool busy =
        _change == _Change.sending || _change == _Change.restarting;
    final FirmwareVersion? bundled = ref.watch(
      bundledFirmwareProvider.select((FirmwareBundle? b) => b?.version),
    );
    final FirmwareVersion? installed = FirmwareVersion.tryParse(version);
    final bool wireless = status.view?.firmware?.wirelessUpdates ?? false;
    final bool needsUsb = status.view?.firmware?.needsUsbInstall ?? false;
    // The finished update's transfer, measured (no pacing depends on it).
    final UpdateStats? stats = ref.watch(
      updateProgressProvider(
        widget.fixtureId,
      ).select((UpdateProgress? p) => p == null || p.running ? null : p.stats),
    );

    if (status.isReady && !setup && !_diagAsked) {
      _diagAsked = true;
      scheduleMicrotask(() => unawaited(_readDiag()));
    }

    final TextStyle title = settingsTitleStyle(context);
    final TextStyle detail = settingsDetailStyle(context);
    final Color fg = settingsInk(context);

    Widget note(String text, {Key? key}) => ListTile(
      key: key,
      title: Text(text, style: detail),
    );

    final List<Widget> typeRows = <Widget>[
      ListTile(
        title: Align(
          alignment: Alignment.centerLeft,
          child: setup
              ? const SetupNeededBadge()
              : FixtureTypeBadge(layout: f.layout, whitePoints: f.whitePoints),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: Space.xxs),
          child: Text(
            setup
                ? l.setupBody(f.name)
                : '${fixtureTypeDescription(l, f.layout)} · '
                      '${presenceText(l, status, bluetooth: ref.watch(bluetoothIssueProvider))}',
            style: detail,
          ),
        ),
      ),
      if (!canType && learned && version != null)
        note(
          l.typeNeedsFirmware(version),
          key: const ValueKey<String>('dev-type-needs-firmware'),
        )
      else if (!canType)
        note(l.typeNotReadYet),
      if (canProbe || !learned)
        ListTile(
          key: const ValueKey<String>('dev-find-type'),
          leading: Icon(Icons.search_rounded, color: fg),
          title: Text(l.findRightType, style: title),
          subtitle: Text(l.findRightTypeHint, style: detail),
          trailing: Icon(Icons.chevron_right_rounded, color: fg),
          enabled: connected && canProbe && !busy,
          onTap: () => unawaited(_probe()),
        ),
    ];

    final List<Widget> typeList = <Widget>[
      for (final ChannelLayout t in fixtureTypes)
        _TypeRow(
          layout: t,
          whitePoints: f.whitePoints,
          current: !setup && t == f.layout,
          suggested: t == _suggested,
          selected: t == _selected,
          enabled: canType && !busy,
          onTap: () => setState(() => _selected = t),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.m, Space.s),
        child: FilledButton(
          key: const ValueKey<String>('dev-change-type'),
          onPressed:
              connected &&
                  canType &&
                  !busy &&
                  _selected != null &&
                  (setup || _selected != f.layout)
              ? () => unawaited(_changeType(f, _selected!))
              : null,
          child: Text(l.changeType),
        ),
      ),
      if (_change != null)
        _ChangeProgress(
          key: const ValueKey<String>('dev-change-result'),
          text: switch (_change!) {
            _Change.sending || _Change.restarting => l.typeRestarting(
              fixtureTypeName(l, _target!),
            ),
            _Change.done => l.layoutChanged(
              f.name,
              fixtureTypeName(l, _target!),
            ),
            _Change.failed => l.typeChangeFailed,
            _Change.notBack => l.typeChangeNoReconnect,
          },
          busy: busy,
          ok: _change == _Change.done,
        ),
    ];

    return SettingsPage(
      title: setup ? l.setupTitle : f.name,
      children: <Widget>[
        SettingsSection(heading: l.fixtureType, children: typeRows),
        SettingsSection(children: typeList),
        if (!setup) ...<Widget>[
          SettingsSection(
            heading: l.firmware,
            children: <Widget>[
              ListTile(
                key: const ValueKey<String>('dev-firmware'),
                title: Text(l.installedVersion, style: title),
                trailing: Text(
                  version ?? l.notReadYet,
                  style: title.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              if (bundled != null)
                ListTile(
                  key: const ValueKey<String>('dev-bundled-firmware'),
                  title: Text(l.bundledVersion, style: title),
                  trailing: Text(
                    '$bundled',
                    style: title.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              if (bundled != null)
                _reinstallRow(
                  l,
                  title,
                  detail,
                  fg,
                  bundled: bundled,
                  installed: installed,
                  enabled: status.isConnected && wireless && !busy,
                  wireless: wireless || !status.isConnected,
                  needsUsb: needsUsb,
                ),
              // Debug builds only (release builds have neither the images nor
              // this option).
              if (rollbackTestsAvailable)
                ListTile(
                  key: const ValueKey<String>('dev-rollback-test'),
                  leading: Icon(Icons.history_rounded, color: fg),
                  title: Text(l.rollbackTestInstall, style: title),
                  subtitle: Text(l.rollbackTestHint, style: detail),
                  trailing: Icon(Icons.chevron_right_rounded, color: fg),
                  enabled: status.isConnected && wireless && !busy,
                  onTap: () => unawaited(_rollbackTest()),
                ),
              if (stats != null)
                ListTile(
                  key: const ValueKey<String>('dev-update-stats'),
                  title: Text(l.updateTransferStats, style: title),
                  subtitle: Text(
                    l.updateTransferStatsDetail(
                      (stats.bytesPerSecond / 1000).toStringAsFixed(1),
                      stats.windowResends,
                      stats.resumes,
                    ),
                    style: detail.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          SettingsSection(
            heading: l.diagnostics,
            children: <Widget>[
              ..._diagRows(l, title, detail, connected: status.isReady),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xs,
                  0,
                  Space.xs,
                  Space.xxs,
                ),
                child: Row(
                  children: <Widget>[
                    TextButton.icon(
                      key: const ValueKey<String>('dev-diag-refresh'),
                      onPressed: status.isReady && !_diagBusy
                          ? () => unawaited(_readDiag())
                          : null,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(l.refresh),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      key: const ValueKey<String>('dev-diag-copy'),
                      onPressed: _diag == null
                          ? null
                          : () => _copy(l, f, version),
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(l.copy),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Debug builds: pick a rollback test image, then install it.
  Future<void> _rollbackTest() async {
    final AppLocalizations l = AppLocalizations.of(context);
    final RollbackTest? test = await showModalBottomSheet<RollbackTest>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.xs),
              child: Text(
                l.rollbackTestChoose,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              key: const ValueKey<String>('rollback-fails-check'),
              leading: const Icon(Icons.rule_rounded),
              title: Text(l.rollbackTestFailsCheck),
              subtitle: Text(l.rollbackTestFailsCheckHint),
              onTap: () => Navigator.of(ctx).pop(RollbackTest.failsCheck),
            ),
            ListTile(
              key: const ValueKey<String>('rollback-freezes'),
              leading: const Icon(Icons.ac_unit_rounded),
              title: Text(l.rollbackTestFreezes),
              subtitle: Text(l.rollbackTestFreezesHint),
              onTap: () => Navigator.of(ctx).pop(RollbackTest.freezes),
            ),
          ],
        ),
      ),
    );
    if (test == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpdateFirmwareScreen(
          fixtureId: widget.fixtureId,
          rollbackTest: test,
        ),
      ),
    );
  }

  /// Reinstall firmware: the update flow with the reinstall flag. Never a
  /// downgrade; a light without wireless updates gets the USB note.
  Widget _reinstallRow(
    AppLocalizations l,
    TextStyle title,
    TextStyle detail,
    Color fg, {
    required FirmwareVersion bundled,
    required FirmwareVersion? installed,
    required bool enabled,
    required bool wireless,
    required bool needsUsb,
  }) {
    final bool newer = installed != null && installed > bundled;
    final String hint = needsUsb
        ? l.updateNeedsUsbInstall
        : !wireless && installed != null
        ? l.updateNeedsUsb('$installed')
        : newer
        ? l.reinstallNewer('$bundled')
        : installed != null && installed < bundled
        ? l.installHint('$bundled')
        : l.reinstallHint('$bundled');
    final bool can = enabled && !newer;
    return ListTile(
      key: const ValueKey<String>('dev-reinstall'),
      leading: Icon(Icons.system_update_alt_rounded, color: fg),
      title: Text(l.reinstallFirmware, style: title),
      subtitle: Text(hint, style: detail),
      trailing: can ? Icon(Icons.chevron_right_rounded, color: fg) : null,
      enabled: can,
      onTap: can
          ? () => unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => UpdateFirmwareScreen(
                    fixtureId: widget.fixtureId,
                    reinstall: true,
                  ),
                ),
              ),
            )
          : null,
    );
  }

  List<Widget> _diagRows(
    AppLocalizations l,
    TextStyle title,
    TextStyle detail, {
    required bool connected,
  }) {
    final DiagReport? d = _diag;
    if (d == null) {
      return <Widget>[
        ListTile(
          title: Text(
            _diagBusy
                ? l.presenceConnecting
                : !connected
                ? l.diagConnect
                : _diagFailed
                ? l.diagNoAnswer
                : l.notReadYet,
            style: detail,
          ),
        ),
      ];
    }
    Widget value(String k, String v, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.m,
        vertical: Space.xxs + 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(k, style: detail)),
          const SizedBox(width: Space.s),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.end,
              style: title.copyWith(
                fontSize: 13,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 2),
      child: Text(
        text.toUpperCase(),
        style: detail.copyWith(fontSize: 11, letterSpacing: 0.4),
      ),
    );
    final List<Widget> rows = <Widget>[
      if (d.uptime != null)
        value(
          l.diagUptime,
          formatUptime(d.uptime!),
          key: const ValueKey<String>('diag-uptime'),
        ),
      if (d.restart != null)
        value(
          l.diagRestart,
          restartReasonText(l, d.restart!),
          key: const ValueKey<String>('diag-restart'),
        ),
      if (d.slot != null) value(l.diagSlot, '${d.slot}'),
      if (d.rolledBack != null)
        value(
          l.diagRollback,
          d.rolledBack! ? l.diagRolledBack : l.diagNotRolledBack,
        ),
      if (d.pendingVerify != null)
        value(
          l.diagConfirmation,
          d.pendingVerify! ? l.diagPendingVerify : l.diagConfirmed,
        ),
    ];
    for (final DiagGroup g in DiagGroup.values) {
      final List<(String, int)> counters = d.counters(g);
      if (counters.isEmpty) continue;
      rows.add(heading(diagGroupName(l, g)));
      for (final (String k, int v) in counters) {
        rows.add(value(diagKeyName(l, k), '$v'));
      }
    }
    rows.add(const SizedBox(height: Space.xs));
    return rows;
  }

  void _copy(AppLocalizations l, Fixture f, String? version) {
    final DiagReport d = _diag!;
    unawaited(
      Clipboard.setData(
        ClipboardData(
          text: diagText(l, d, name: f.name, version: version),
        ),
      ),
    );
    showGlassToast(context, l.copied, icon: Icons.copy_rounded);
  }
}

/// A restart reason in plain words.
String restartReasonText(AppLocalizations l, RestartReason r) => switch (r) {
  RestartReason.unknown => l.restartUnknown,
  RestartReason.powerOn => l.restartPowerOn,
  RestartReason.resetPin => l.restartResetPin,
  RestartReason.software => l.restartSoftware,
  RestartReason.crash => l.restartCrash,
  RestartReason.interruptWatchdog => l.restartInterruptWatchdog,
  RestartReason.taskWatchdog => l.restartTaskWatchdog,
  RestartReason.otherWatchdog => l.restartOtherWatchdog,
  RestartReason.deepSleep => l.restartDeepSleep,
  RestartReason.brownout => l.restartBrownout,
  RestartReason.sdio => l.restartSdio,
  RestartReason.usb => l.restartUsb,
  RestartReason.jtag => l.restartJtag,
  RestartReason.efuse => l.restartEfuse,
  RestartReason.powerGlitch => l.restartPowerGlitch,
  RestartReason.cpuLockup => l.restartCpuLockup,
};

String diagGroupName(AppLocalizations l, DiagGroup g) => switch (g) {
  DiagGroup.render => l.diagRender,
  DiagGroup.connection => l.diagConnection,
  DiagGroup.system => l.diagSystem,
  DiagGroup.other => l.diagOther,
};

/// A DIAG counter's name; a key the app doesn't know stays as sent.
String diagKeyName(AppLocalizations l, String key) => switch (key) {
  'frames' => l.diagKeyFrames,
  'overrun' => l.diagKeyOverrun,
  'rmaxus' => l.diagKeyRmaxus,
  'rx' => l.diagKeyRx,
  'bin' => l.diagKeyBin,
  'gaps' => l.diagKeyGaps,
  'binbad' => l.diagKeyBinbad,
  'unk' => l.diagKeyUnk,
  'err' => l.diagKeyErr,
  'coal' => l.diagKeyCoal,
  'ovf' => l.diagKeyOvf,
  'rej' => l.diagKeyRej,
  'sdrop' => l.diagKeySdrop,
  'nretry' => l.diagKeyNretry,
  'edrop' => l.diagKeyEdrop,
  'heapmin' => l.diagKeyHeapmin,
  'stkc' => l.diagKeyStkc,
  'stkr' => l.diagKeyStkr,
  'nvsw' => l.diagKeyNvsw,
  'nvsf' => l.diagKeyNvsf,
  'endms' => l.diagKeyEndms,
  _ => key,
};

/// The diagnostics as text (Copy): readable lines, then the raw reply.
String diagText(
  AppLocalizations l,
  DiagReport d, {
  required String name,
  String? version,
}) {
  final StringBuffer b = StringBuffer(name);
  if (version != null) b.write(' · ${l.firmwareVersionShort(version)}');
  b.writeln();
  if (d.uptime != null) {
    b.writeln('${l.diagUptime}: ${formatUptime(d.uptime!)}');
  }
  if (d.restart != null) {
    b.writeln('${l.diagRestart}: ${restartReasonText(l, d.restart!)}');
  }
  if (d.slot != null) b.writeln('${l.diagSlot}: ${d.slot}');
  if (d.rolledBack != null) {
    b.writeln(
      '${l.diagRollback}: '
      '${d.rolledBack! ? l.diagRolledBack : l.diagNotRolledBack}',
    );
  }
  if (d.pendingVerify != null) {
    b.writeln(
      '${l.diagConfirmation}: '
      '${d.pendingVerify! ? l.diagPendingVerify : l.diagConfirmed}',
    );
  }
  for (final DiagGroup g in DiagGroup.values) {
    final List<(String, int)> counters = d.counters(g);
    if (counters.isEmpty) continue;
    b.writeln('${diagGroupName(l, g)}:');
    for (final (String k, int v) in counters) {
      b.writeln('  ${diagKeyName(l, k)}: $v');
    }
  }
  b.write(d.raw);
  return b.toString();
}

/// One fixture type in the type list: its LEDs, name and meaning, marked
/// current or suggested, checked when selected.
class _TypeRow extends StatelessWidget {
  const _TypeRow({
    required this.layout,
    required this.whitePoints,
    required this.current,
    required this.suggested,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ChannelLayout layout;
  final LedWhitePoints whitePoints;
  final bool current;
  final bool suggested;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Color fg = settingsInk(context);
    final String? tag = current
        ? l.currentType
        : suggested
        ? l.suggested
        : null;
    return Semantics(
      selected: selected,
      child: ListTile(
        key: ValueKey<String>('dev-type-${layout.wire}'),
        enabled: enabled,
        onTap: onTap,
        leading: SizedBox(
          width: 52,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ChannelDots(
              layout: layout,
              whitePoints: whitePoints,
              size: 7,
            ),
          ),
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                fixtureTypeName(l, layout),
                style: settingsTitleStyle(context),
              ),
            ),
            if (tag != null) ...<Widget>[
              const SizedBox(width: Space.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.xs,
                  vertical: 2,
                ),
                decoration: ShapeDecoration(
                  shape: const StadiumBorder(),
                  color: fg.withValues(alpha: 0.08),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.75),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          fixtureTypeDescription(l, layout),
          style: settingsDetailStyle(context),
        ),
        trailing: Icon(
          selected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: fg.withValues(alpha: selected ? 0.9 : 0.35),
        ),
      ),
    );
  }
}

/// The type change's progress (a spinner while the light restarts) or result.
class _ChangeProgress extends StatelessWidget {
  const _ChangeProgress({
    required this.text,
    required this.busy,
    required this.ok,
    super.key,
  });
  final String text;
  final bool busy;
  final bool ok;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: ListTile(
      leading: busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            )
          : Icon(
              ok ? Icons.check_circle_rounded : Icons.info_outline_rounded,
              color: settingsInk(context),
            ),
      title: Text(text, style: settingsTitleStyle(context)),
    ),
  );
}
