import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../core/color/colour_engine.dart';
import '../core/color/led_white_points.dart';
import '../core/color/steady_colour.dart';
import '../core/model/channel_color.dart';
import '../core/model/fixture.dart';
import '../core/model/light_capabilities.dart';
import '../core/protocol/eb/eb_fixture_catalog.dart';
import '../core/protocol/eb/eb_scene.dart';
import '../core/model/channel_layout.dart';
import '../sessions/discovery.dart';
import '../sessions/fixture_registry.dart';
import '../drivers/electrobright/eb_types.dart';
import '../sessions/fixture_session.dart';
import '../sessions/group_session.dart';
import 'app_session.dart';

/// The saved lights (live).
final NotifierProvider<FixturesNotifier, List<Fixture>> fixturesProvider =
    NotifierProvider<FixturesNotifier, List<Fixture>>(FixturesNotifier.new);

final class FixturesNotifier extends Notifier<List<Fixture>> {
  @override
  List<Fixture> build() {
    final FixtureRegistry? reg = ref.watch(appSessionProvider)?.registry;
    if (reg == null) return const <Fixture>[];
    final StreamSubscription<List<Fixture>> sub = reg.changes.listen(
      (List<Fixture> l) => state = l,
    );
    ref.onDispose(sub.cancel);
    return reg.fixtures;
  }
}

/// One saved light.
final ProviderFamily<Fixture?, String> fixtureProvider =
    Provider.family<Fixture?, String>(
      (Ref ref, String id) => ref.watch(
        fixturesProvider.select(
          (List<Fixture> l) => l.where((Fixture f) => f.id == id).firstOrNull,
        ),
      ),
    );

/// The live session of a saved light (null when BLE is not running).
final ProviderFamily<FixtureSession?, String> fixtureSessionProvider =
    Provider.family<FixtureSession?, String>(
      (Ref ref, String id) =>
          ref.watch(appSessionProvider)?.ble.connections.session(id),
    );

/// Connection phase, live view and last-known state of a light.
final NotifierProviderFamily<FixtureStatusNotifier, FixtureStatus, String>
fixtureStatusProvider =
    NotifierProvider.family<FixtureStatusNotifier, FixtureStatus, String>(
      FixtureStatusNotifier.new,
    );

final class FixtureStatusNotifier extends Notifier<FixtureStatus> {
  FixtureStatusNotifier(this.id);
  final String id;

  @override
  FixtureStatus build() {
    final FixtureSession? s = ref.watch(fixtureSessionProvider(id));
    if (s == null) return const FixtureStatus(phase: LinkPhase.idle);
    final StreamSubscription<FixtureStatus> sub = s.statuses.listen(
      (FixtureStatus st) => state = st,
    );
    ref.onDispose(sub.cancel);
    return s.status;
  }
}

/// What a light can do: live from its firmware, else as saved, else assumed
/// from its layout. Every control screen is built from this (also offline).
final ProviderFamily<LightCapabilities?, String> capabilitiesProvider =
    Provider.family<LightCapabilities?, String>((Ref ref, String id) {
      final LightCapabilities? live = ref.watch(
        fixtureStatusProvider(id)
            .select((FixtureStatus s) => s.view?.firmware?.capabilities),
      );
      if (live != null) return live;
      return ref.watch(fixtureProvider(id))?.capabilities;
    });

/// The light's current scene (live or last known).
final ProviderFamily<EbScene?, String> sceneProvider =
    Provider.family<EbScene?, String>(
      (Ref ref, String id) => ref.watch(
        fixtureStatusProvider(id).select((FixtureStatus s) => s.state?.scene),
      ),
    );

/// A light's picked colour at full intensity as the UI shows it (pill, orb,
/// canvas, glyphs), chosen by where the colour came from: while the
/// session's colour is the change that sent the user's pick on this phone,
/// exactly that pick (also after release, until the light reports a colour
/// of its own); otherwise the channels, held steady at low values. One
/// status carries both, so the choice never flips between frames.
final NotifierProviderFamily<SteadyLevelsNotifier, SteadyLevels?, String>
steadyLevelsProvider =
    NotifierProvider.family<SteadyLevelsNotifier, SteadyLevels?, String>(
      SteadyLevelsNotifier.new,
    );

final class SteadyLevelsNotifier extends Notifier<SteadyLevels?> {
  SteadyLevelsNotifier(this.id);
  final String id;

  @override
  SteadyLevels? build() {
    final (ChannelColor?, EbColorOrigin?, ColourPick?) s = ref.watch(
      fixtureStatusProvider(id).select(
        (FixtureStatus s) =>
            (s.state?.scene.color, s.view?.colorOrigin, s.colourPick),
      ),
    );
    final (ChannelColor? c, EbColorOrigin? origin, ColourPick? pick) = s;
    final LedWhitePoints wp = ref.watch(
      fixtureProvider(id)
          .select((Fixture? f) => f?.whitePoints ?? const LedWhitePoints()),
    );
    final bool picked =
        c != null &&
        origin != null &&
        origin.byUser &&
        pick != null &&
        pick.seq == origin.seq;
    if (!picked) return SteadyLevels.next(stateOrNull, c);
    return switch (pick.intent) {
      RawIntent() => SteadyLevels.next(stateOrNull, c, exact: true),
      final ColourIntent i => SteadyLevels.next(
        stateOrNull,
        c,
        intent: ColourEngine(wp).fullLevels(i, c.layout),
      ),
    };
  }
}

/// A light advertising nearby that is not saved yet.
final class NearbyLight {
  const NearbyLight(this.seen, this.layoutHint);
  final SeenDevice seen;

  /// From the advertised name; confirmed by the light when it connects.
  final ChannelLayout? layoutHint;
  bool get isLegacy => seen.deviceClass == DeviceClass.legacyElectroBright;
}

/// Unsaved ElectroBright lights nearby, strongest first. Watching it keeps a
/// fast scan running.
final NotifierProvider<NearbyNotifier, List<NearbyLight>> nearbyProvider =
    NotifierProvider.autoDispose<NearbyNotifier, List<NearbyLight>>(
      NearbyNotifier.new,
    );

final class NearbyNotifier extends Notifier<List<NearbyLight>> {
  @override
  List<NearbyLight> build() {
    final AppSession? app = ref.watch(appSessionProvider);
    if (app == null) return const <NearbyLight>[];
    final Discovery d = app.ble.discovery;
    final ScanLease lease = d.acquire(ScanNeed.addFlow);
    List<NearbyLight> compute() {
      final Set<String> saved = ref
          .read(fixturesProvider)
          .map((Fixture f) => f.deviceId)
          .toSet();
      final List<NearbyLight> out =
          <NearbyLight>[
            for (final SeenDevice s in d.devices)
              if (!saved.contains(s.id) && s.deviceClass != DeviceClass.other)
                NearbyLight(s, EbFixtureCatalog.layoutFromBleName(s.name)),
          ]..sort(
            (NearbyLight a, NearbyLight b) =>
                b.seen.rssi.compareTo(a.seen.rssi),
          );
      return out;
    }

    // Only a change to what the list shows is written (and heard): in
    // debug builds any write also rebuilds the provider scope.
    void update() {
      final List<NearbyLight> next = compute();
      if (updateShouldNotify(state, next)) state = next;
    }

    final StreamSubscription<SeenDevice> sub = d.updates.listen((SeenDevice s) {
      // Another kind of device can't join the list; it matters only if it
      // is listed already.
      if (s.deviceClass == DeviceClass.other &&
          !state.any((NearbyLight n) => n.seen.id == s.id)) {
        return;
      }
      update();
    });
    final StreamSubscription<String> forgotten = d.forgotten.listen(
      (_) => update(),
    );
    ref.listen(fixturesProvider, (_, _) => update());
    ref.onDispose(() {
      unawaited(sub.cancel());
      unawaited(forgotten.cancel());
      lease.release();
    });
    return compute();
  }

  /// Listeners hear of a change only when what the list shows changes: the
  /// lights, their order, names, types and signal bars (not every RSSI
  /// wobble).
  @override
  bool updateShouldNotify(List<NearbyLight> previous, List<NearbyLight> next) {
    if (previous.length != next.length) return true;
    for (int i = 0; i < next.length; i++) {
      final NearbyLight a = previous[i], b = next[i];
      if (a.seen.id != b.seen.id ||
          a.seen.name != b.seen.name ||
          a.layoutHint != b.layoutHint ||
          a.seen.signalBars != b.seen.signalBars) {
        return true;
      }
    }
    return false;
  }
}

/// All Lights (null when BLE is not running).
final Provider<GroupSession?> groupSessionProvider = Provider<GroupSession?>(
  (Ref ref) => ref.watch(appSessionProvider)?.group,
);

/// The group's members and counts.
final NotifierProvider<GroupStatusNotifier, GroupStatus> groupStatusProvider =
    NotifierProvider<GroupStatusNotifier, GroupStatus>(GroupStatusNotifier.new);

final class GroupStatusNotifier extends Notifier<GroupStatus> {
  @override
  GroupStatus build() {
    final GroupSession? g = ref.watch(groupSessionProvider);
    if (g == null) return const GroupStatus();
    final StreamSubscription<GroupStatus> sub = g.statuses.listen(
      (GroupStatus s) => state = s,
    );
    ref.onDispose(sub.cancel);
    return g.status;
  }
}

/// What the group's ready lights show together; read through the providers
/// below, so each control hears only of what it shows.
final NotifierProvider<_GroupLookNotifier, GroupLook> _groupLookProvider =
    NotifierProvider<_GroupLookNotifier, GroupLook>(_GroupLookNotifier.new);

final class _GroupLookNotifier extends Notifier<GroupLook> {
  @override
  GroupLook build() {
    final GroupSession? g = ref.watch(groupSessionProvider);
    if (g == null) return const GroupLook();
    final StreamSubscription<GroupLook> sub = g.looks.listen(
      (GroupLook l) => state = l,
    );
    ref.onDispose(sub.cancel);
    return g.look;
  }
}

/// The ready lights' common brightness, or mixed.
final Provider<Common<int>> groupBrightnessProvider = Provider<Common<int>>(
  (Ref ref) =>
      ref.watch(_groupLookProvider.select((GroupLook l) => l.brightness)),
);

/// Whether any ready light is on.
final Provider<bool> groupAnyOnProvider = Provider<bool>(
  (Ref ref) => ref.watch(_groupLookProvider.select((GroupLook l) => l.anyOn)),
);

/// The ready lights' common mode, or mixed.
final Provider<Common<int>> groupModeProvider = Provider<Common<int>>(
  (Ref ref) => ref.watch(_groupLookProvider.select((GroupLook l) => l.mode)),
);

/// The ready lights' common colour, or mixed.
final Provider<Common<ColourIntent>> groupColourProvider =
    Provider<Common<ColourIntent>>(
      (Ref ref) =>
          ref.watch(_groupLookProvider.select((GroupLook l) => l.colour)),
    );

/// The ready lights' common sleep-timer deadline (within 2 s), mixed or none.
final Provider<Common<Duration>> groupTimerProvider =
    Provider<Common<Duration>>(
      (Ref ref) => ref.watch(
        _groupLookProvider.select((GroupLook l) => l.timerDeadline),
      ),
    );
