import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/firmware/firmware_bundle.dart';
import '../../core/model/fixture.dart';
import '../../sessions/firmware_update.dart';
import '../../sessions/fixture_session.dart';

/// The firmware bundled with the app (null before a session, or none).
final Provider<FirmwareBundle?> bundledFirmwareProvider =
    Provider<FirmwareBundle?>(
      (Ref ref) => ref.watch(appSessionProvider)?.firmware,
    );

/// Whether a connected light can be updated to the bundled firmware (older,
/// with the update service; never a downgrade).
final ProviderFamily<bool, String> updateAvailableProvider =
    Provider.family<bool, String>((Ref ref, String id) {
      final FirmwareVersion? bundled = ref.watch(
        bundledFirmwareProvider.select((FirmwareBundle? b) => b?.version),
      );
      return ref.watch(
        fixtureStatusProvider(id)
            .select((FixtureStatus s) => FirmwareUpdates.offers(s, bundled)),
      );
    });

/// The saved lights with an update available, in Home's order.
final Provider<List<String>> lightsWithUpdateProvider = Provider<List<String>>(
  (Ref ref) => <String>[
    for (final Fixture f in ref.watch(fixturesProvider))
      if (ref.watch(updateAvailableProvider(f.id))) f.id,
  ],
);

/// A light's latest update progress (null when it has none to show).
final NotifierProviderFamily<UpdateProgressNotifier, UpdateProgress?, String>
updateProgressProvider =
    NotifierProvider.family<UpdateProgressNotifier, UpdateProgress?, String>(
      UpdateProgressNotifier.new,
    );

final class UpdateProgressNotifier extends Notifier<UpdateProgress?> {
  UpdateProgressNotifier(this.id);
  final String id;

  @override
  UpdateProgress? build() {
    final FirmwareUpdates? updates = ref.watch(appSessionProvider)?.updates;
    if (updates == null) return null;
    final StreamSubscription<UpdateProgress> sub = updates.changes
        .where((UpdateProgress p) => p.fixtureId == id)
        .listen((UpdateProgress p) => state = p);
    ref.onDispose(sub.cancel);
    return updates.progressOf(id);
  }

  /// Forgets a finished result (the screen starts over).
  void clear() {
    final UpdateProgress? p = state;
    if (p == null || p.running) return;
    ref.read(appSessionProvider)?.updates.clear(id);
    state = null;
  }
}

/// The light being updated right now, if any (one at a time).
final NotifierProvider<ActiveUpdateNotifier, String?> activeUpdateProvider =
    NotifierProvider<ActiveUpdateNotifier, String?>(ActiveUpdateNotifier.new);

final class ActiveUpdateNotifier extends Notifier<String?> {
  @override
  String? build() {
    final FirmwareUpdates? updates = ref.watch(appSessionProvider)?.updates;
    if (updates == null) return null;
    final StreamSubscription<UpdateProgress> sub = updates.changes.listen((
      UpdateProgress p,
    ) {
      if (p.running) {
        state = p.fixtureId;
      } else if (state == p.fixtureId) {
        state = null;
      }
    });
    ref.onDispose(sub.cancel);
    return updates.activeId;
  }
}
