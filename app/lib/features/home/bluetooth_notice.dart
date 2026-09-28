import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/bluetooth_access.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../l10n/app_localizations.dart';

/// Why Bluetooth can't be used (off, not allowed, unsupported, Location
/// Services off) and what to do about it. Home, Add light and the group
/// screen show it; nothing while Bluetooth is usable.
class BluetoothNotice extends ConsumerWidget {
  const BluetoothNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BluetoothIssue? issue = ref.watch(bluetoothIssueProvider);
    if (issue == null) return const SizedBox.shrink();
    final AppLocalizations l = AppLocalizations.of(context);
    final BluetoothAccess? access = ref.watch(
      appSessionProvider.select((AppSession? a) => a?.bluetooth),
    );
    final bool android =
        access?.android ?? defaultTargetPlatform == TargetPlatform.android;
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final (IconData icon, String title, String body) = switch (issue) {
      BluetoothIssue.off => (
        Icons.bluetooth_disabled_rounded,
        l.bluetoothOffTitle,
        android ? l.bluetoothOffBody : l.bluetoothOffBodyIos,
      ),
      BluetoothIssue.denied => (
        Icons.block_rounded,
        l.bluetoothDeniedTitle,
        l.bluetoothDeniedBody,
      ),
      BluetoothIssue.unsupported => (
        Icons.bluetooth_disabled_rounded,
        l.bluetoothUnsupportedTitle,
        l.bluetoothUnsupportedBody,
      ),
      BluetoothIssue.locationOff => (
        Icons.location_off_rounded,
        l.bluetoothLocationTitle,
        l.bluetoothLocationBody,
      ),
    };
    final BluetoothIssueAction? action = access == null
        ? null
        : actionFor(issue, android: android);
    return Semantics(
      container: true,
      liveRegion: true,
      child: GlassSurface(
        key: ValueKey<String>('bluetooth-notice-${issue.name}'),
        radius: Radii.medium,
        tinted: false,
        elevated: false,
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 20, color: fg.withValues(alpha: 0.8)),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: TextStyle(
                        color: fg,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(body, style: TextStyle(color: fg.withValues(alpha: 0.75))),
            if (action != null) ...<Widget>[
              const SizedBox(height: Space.s),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonal(
                  key: const ValueKey<String>('bluetooth-notice-action'),
                  onPressed: () => unawaited(access!.resolve(issue)),
                  child: Text(switch (action) {
                    BluetoothIssueAction.turnOn => l.turnOnBluetooth,
                    BluetoothIssueAction.openSettings => l.openSettings,
                  }),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
