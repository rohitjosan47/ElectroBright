import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/firmware/firmware_bundle.dart';
import '../../core/model/fixture.dart';
import '../../design/components/settings_list.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/firmware_update.dart';
import '../../sessions/fixture_session.dart';
import '../developer/rollback_test.dart';
import '../shared/removed_screen.dart';
import 'update_providers.dart';

/// A light's wireless firmware update: what will happen, then the transfer
/// (progress, time left, Cancel while that is safe) and the result. With
/// [reinstall] (developer tools) the bundled version is sent even when the
/// light already runs it. With [rollbackTest] (debug builds only) it installs
/// that rollback test image instead, and the expected result is the light
/// back on its previous firmware. Never offers a downgrade. Keeps the light
/// connected while open (the screen stays awake while an update runs, see
/// AppSession).
class UpdateFirmwareScreen extends ConsumerStatefulWidget {
  const UpdateFirmwareScreen({
    required this.fixtureId,
    this.reinstall = false,
    this.rollbackTest,
    super.key,
  });

  final String fixtureId;
  final bool reinstall;
  final RollbackTest? rollbackTest;

  @override
  ConsumerState<UpdateFirmwareScreen> createState() =>
      _UpdateFirmwareScreenState();
}

class _UpdateFirmwareScreenState extends ConsumerState<UpdateFirmwareScreen> {
  Want? _want;

  /// The rollback test image, when this is a rollback test.
  late final FirmwareBundle? _testImage = widget.rollbackTest == null
      ? null
      : rollbackTestImage(widget.rollbackTest!);

  @override
  void initState() {
    super.initState();
    final AppSession? app = ref.read(appSessionProvider);
    if (app?.ble.connections.session(widget.fixtureId) != null) {
      _want = app!.ble.connections.want(widget.fixtureId, WantReason.screen);
    }
    // An earlier result is not this visit's: start over.
    final UpdateProgress? p = ref.read(
      updateProgressProvider(widget.fixtureId),
    );
    if (p != null && !p.running) {
      scheduleMicrotask(
        () =>
            ref.read(updateProgressProvider(widget.fixtureId).notifier).clear(),
      );
    }
  }

  @override
  void dispose() {
    _want?.release();
    super.dispose();
  }

  void _start(FirmwareBundle bundle) {
    final AppSession app = ref.read(appSessionProvider)!;
    unawaited(
      app.updates.start(
        widget.fixtureId,
        version: bundle.version,
        image: bundle.image,
        reinstall: widget.reinstall,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture? f = ref.watch(fixtureProvider(widget.fixtureId));
    if (f == null) return RemovedScreen(message: l.lightRemovedNotice);
    final FirmwareBundle? bundled = ref.watch(bundledFirmwareProvider);
    final FirmwareBundle? bundle = widget.rollbackTest == null
        ? bundled
        : _testImage;
    final UpdateProgress? progress = ref.watch(
      updateProgressProvider(widget.fixtureId),
    );
    final String? active = ref.watch(activeUpdateProvider);
    final (bool connected, String? live, bool needsUsb) = ref.watch(
      fixtureStatusProvider(widget.fixtureId).select(
        (FixtureStatus s) => (
          s.isConnected,
          s.view?.firmware?.version.version,
          s.view?.firmware?.needsUsbInstall ?? false,
        ),
      ),
    );
    ref.listen<UpdateProgress?>(updateProgressProvider(widget.fixtureId), (
      UpdateProgress? before,
      UpdateProgress? now,
    ) {
      if (now != null && before?.stage != now.stage && now.stage.finished) {
        HapticsScope.of(context).play(
          now.stage == UpdateStage.done
              ? HapticEvent.success
              : now.stage == UpdateStage.cancelled
              ? HapticEvent.selection
              : HapticEvent.warning,
        );
      }
    });

    final FirmwareVersion? installed = FirmwareVersion.tryParse(
      live ?? f.identity?.firmwareVersion,
    );
    final FirmwareVersion? to = progress?.to ?? bundle?.version;
    final FirmwareVersion? from = progress?.from ?? installed;

    final List<Widget> body = switch (progress) {
      null => _intro(l, f, bundle, installed, connected, active, needsUsb),
      final UpdateProgress p when p.running => _running(l, p),
      final UpdateProgress p => _result(l, f, p, bundle),
    };

    return SettingsPage(
      title: widget.rollbackTest != null
          ? l.rollbackTestTitle
          : widget.reinstall
          ? l.reinstallFirmware
          : l.updateFirmware,
      children: <Widget>[
        SettingsSection(
          children: <Widget>[
            ListTile(
              leading: Icon(
                Icons.system_update_alt_rounded,
                color: settingsInk(context),
              ),
              title: Text(f.name, style: settingsTitleStyle(context)),
              subtitle: to == null
                  ? null
                  : Text(
                      from == null || from == to
                          ? '$to'
                          : l.updateVersions('$from', '$to'),
                      key: const ValueKey<String>('update-versions'),
                      style: settingsDetailStyle(context).copyWith(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
            ),
          ],
        ),
        ...body,
      ],
    );
  }

  /// Before an update: what will happen, and Update (when it can run).
  List<Widget> _intro(
    AppLocalizations l,
    Fixture f,
    FirmwareBundle? bundle,
    FirmwareVersion? installed,
    bool connected,
    String? active,
    bool needsUsb,
  ) {
    final TextStyle title = settingsTitleStyle(context);
    final TextStyle detail = settingsDetailStyle(context);
    final Color fg = settingsInk(context);
    final bool newer =
        bundle != null && installed != null && installed > bundle.version;
    final bool same =
        bundle != null && installed != null && installed == bundle.version;
    final bool other = active != null && active != widget.fixtureId;
    final String? blocker = bundle == null
        ? l.updateBadImage
        : needsUsb
        ? l.updateNeedsUsbInstall
        : newer
        ? l.updateDowngrade
        : same && !widget.reinstall
        ? l.updateSameVersion
        : other
        ? l.updateOtherRunning
        : null;
    return <Widget>[
      SettingsSection(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(switch (widget.rollbackTest) {
                  RollbackTest.failsCheck => l.rollbackTestFailsBody(
                    f.name,
                    '$installed',
                  ),
                  RollbackTest.freezes => l.rollbackTestFreezesBody(
                    f.name,
                    '$installed',
                  ),
                  null =>
                    widget.reinstall
                        ? l.reinstallWhatHappens(f.name, '${bundle?.version}')
                        : l.updateWhatHappens(f.name, '${bundle?.version}'),
                }, style: title.copyWith(fontWeight: FontWeight.w400)),
                const SizedBox(height: Space.s),
                _Note(icon: Icons.phone_iphone_rounded, text: l.updateStayNear),
                const SizedBox(height: Space.xs),
                _Note(icon: Icons.schedule_rounded, text: l.updateDuration),
              ],
            ),
          ),
        ],
      ),
      if (blocker != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.m),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: fg, size: 20),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  blocker,
                  key: const ValueKey<String>('update-blocked'),
                  style: detail,
                ),
              ),
            ],
          ),
        ),
      FilledButton(
        key: const ValueKey<String>('update-start'),
        onPressed: blocker == null && connected ? () => _start(bundle!) : null,
        child: Text(widget.reinstall ? l.reinstallStart : l.updateStart),
      ),
      if (blocker == null && !connected)
        Padding(
          padding: const EdgeInsets.only(top: Space.s),
          child: Text(
            l.presenceConnecting,
            textAlign: TextAlign.center,
            style: detail,
          ),
        ),
    ];
  }

  /// During an update: the stage, progress and time left, and Cancel while
  /// nothing is committed yet.
  List<Widget> _running(AppLocalizations l, UpdateProgress p) {
    final TextStyle title = settingsTitleStyle(context);
    final TextStyle detail = settingsDetailStyle(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final String stage = switch (p.stage) {
      UpdateStage.preparing => l.updateStagePreparing,
      UpdateStage.sending when p.reconnecting => l.updateStageReconnecting,
      UpdateStage.sending => l.updateStageSending,
      UpdateStage.installing => l.updateStageInstalling,
      UpdateStage.restarting => l.updateStageRestarting,
      _ => l.updateStageChecking,
    };
    final bool measured = p.stage == UpdateStage.sending && p.total > 0;
    final int percent = (p.fraction * 100).floor();
    final Duration? left = p.timeLeft;
    return <Widget>[
      SettingsSection(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    stage,
                    key: const ValueKey<String>('update-stage'),
                    style: title,
                  ),
                  const SizedBox(height: Space.s),
                  _ProgressBar(value: measured ? p.fraction : null, dark: dark),
                  const SizedBox(height: Space.xs),
                  Row(
                    children: <Widget>[
                      Text(
                        measured ? l.updatePercent(percent) : '',
                        key: const ValueKey<String>('update-percent'),
                        style: detail.copyWith(
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (measured && left != null)
                        Text(
                          _timeLeft(l, left),
                          key: const ValueKey<String>('update-time-left'),
                          style: detail.copyWith(
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.s),
                  if (p.paused) ...<Widget>[
                    _Note(
                      key: const ValueKey<String>('update-paused'),
                      icon: Icons.pause_circle_outline_rounded,
                      text: l.updatePaused,
                    ),
                    const SizedBox(height: Space.xs),
                  ],
                  _Note(
                    icon: Icons.phone_iphone_rounded,
                    text: l.updateStayNear,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      if (p.cancellable)
        OutlinedButton(
          key: const ValueKey<String>('update-cancel'),
          onPressed: () =>
              ref.read(appSessionProvider)?.updates.cancel(widget.fixtureId),
          child: Text(l.cancel),
        )
      else
        Text(
          l.updateNoStop,
          key: const ValueKey<String>('update-no-stop'),
          textAlign: TextAlign.center,
          style: detail,
        ),
    ];
  }

  /// The outcome, with Done (and Try again when it did not finish).
  List<Widget> _result(
    AppLocalizations l,
    Fixture f,
    UpdateProgress p,
    FirmwareBundle? bundle,
  ) {
    final Color fg = settingsInk(context);
    final bool test = widget.rollbackTest != null;
    final (IconData icon, String heading, String? text) = switch (p.stage) {
      // A rollback test passes when the light went back to the firmware and
      // the slot it ran before, and DIAG says it rolled back.
      UpdateStage.rolledBack when test =>
        p.rolledBackFlag == true &&
                p.slotAfter != null &&
                p.slotAfter == p.slotBefore
            ? (
                Icons.check_circle_rounded,
                l.rollbackTestPassed,
                l.rollbackTestPassedBody(f.name, '${p.from}', p.slotAfter!),
              )
            : (
                Icons.error_outline_rounded,
                l.updateRolledBack,
                l.rollbackTestDiagMismatch(
                  f.name,
                  '${p.from}',
                  '${p.rolledBackFlag == null ? '?' : (p.rolledBackFlag! ? 1 : 0)}',
                  '${p.slotAfter ?? '?'}',
                  '${p.slotBefore ?? '?'}',
                ),
              ),
      UpdateStage.done when test => (
        Icons.error_outline_rounded,
        l.rollbackTestConfirmed,
        l.rollbackTestConfirmedBody,
      ),
      UpdateStage.done => (
        Icons.check_circle_rounded,
        l.updateDone('${p.to}'),
        l.updateDoneBody(f.name, '${p.to}'),
      ),
      UpdateStage.rolledBack => (
        Icons.history_rounded,
        l.updateRolledBack,
        null,
      ),
      UpdateStage.cancelled => (
        Icons.cancel_outlined,
        l.updateCancelled(f.name),
        null,
      ),
      _ => (
        Icons.error_outline_rounded,
        l.updateFailed,
        updateProblemText(l, p.problem),
      ),
    };
    final bool retry =
        p.stage != UpdateStage.done &&
        bundle != null &&
        p.problem != UpdateProblem.downgrade &&
        p.problem != UpdateProblem.sameVersion &&
        p.problem != UpdateProblem.unsupported &&
        p.problem != UpdateProblem.needsUsbInstall;
    return <Widget>[
      SettingsSection(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(icon, color: fg, size: 28),
                  const SizedBox(width: Space.s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          heading,
                          key: const ValueKey<String>('update-result'),
                          style: settingsTitleStyle(context)
                              .copyWith(fontSize: 17),
                        ),
                        if (text != null) ...<Widget>[
                          const SizedBox(height: Space.xxs),
                          Text(text, style: settingsDetailStyle(context)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      FilledButton(
        key: const ValueKey<String>('update-done'),
        onPressed: () => Navigator.of(context).maybePop(),
        child: Text(l.done),
      ),
      if (retry)
        TextButton(
          key: const ValueKey<String>('update-retry'),
          onPressed: () => _start(bundle),
          child: Text(l.tryAgain),
        ),
    ];
  }

  static String _timeLeft(AppLocalizations l, Duration d) {
    final int s = d.inSeconds;
    if (s < 60) return l.updateSecondsLeft(s < 5 ? 5 : (s / 5).ceil() * 5);
    return l.updateMinutesLeft((s / 60).ceil());
  }
}

/// Why an update stopped, in plain words.
String updateProblemText(AppLocalizations l, UpdateProblem? p) => switch (p) {
  UpdateProblem.notConnected => l.updateNotConnected,
  UpdateProblem.unsupported => l.updateUnsupported,
  UpdateProblem.needsUsbInstall => l.updateNeedsUsbInstall,
  UpdateProblem.downgrade => l.updateDowngrade,
  UpdateProblem.sameVersion => l.updateSameVersion,
  UpdateProblem.badImage => l.updateBadImage,
  UpdateProblem.tooBig => l.updateTooBig,
  UpdateProblem.damaged => l.updateDamaged,
  UpdateProblem.notAccepted => l.updateNotAccepted,
  UpdateProblem.flash => l.updateFlash,
  UpdateProblem.busy => l.updateBusy,
  UpdateProblem.badRequest => l.updateBadRequest,
  UpdateProblem.stalled => l.updateStalled,
  UpdateProblem.linkLost => l.updateLinkLost,
  UpdateProblem.noAnswer || null => l.updateNoAnswer,
  UpdateProblem.notBack => l.updateNotBack,
  UpdateProblem.otherVersion => l.updateOtherVersion,
  UpdateProblem.unconfirmed => l.updateUnconfirmed,
  UpdateProblem.anotherUpdate => l.updateOtherRunning,
};

/// A small line with an icon (the update screen's notes).
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, super.key});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final TextStyle detail = settingsDetailStyle(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: detail.color),
        const SizedBox(width: Space.xs),
        Expanded(child: Text(text, style: detail)),
      ],
    );
  }
}

/// The transfer's progress: a capsule track with the brand's periwinkle
/// (never the light's colour); indeterminate when [value] is null.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.dark});
  final double? value;
  final bool dark;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Radii.capsule),
    child: LinearProgressIndicator(
      key: const ValueKey<String>('update-progress'),
      value: value,
      minHeight: 8,
      color: PillFill.of(dark: dark).halo,
      backgroundColor: settingsInk(context).withValues(alpha: 0.12),
    ),
  );
}
