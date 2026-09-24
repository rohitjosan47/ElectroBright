import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Every fixture type (plus a light on the original firmware) through the
/// whole connection stack on simulated radios.
void main() {
  final ManualScheduler clock = ManualScheduler();
  late SimCentral central;
  late Discovery discovery;
  late ConnectionManager manager;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(5);
      clock.advance(step);
    }
    await _pump();
  }

  setUp(() {
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        for (final EbFixtureSpec f in EbFixtureCatalog.all)
          SimFixture.electroBright(id: 'dev-${f.fwsimName}', fixture: f),
        SimFixture.legacy(id: 'dev-legacy'),
      ],
    );
    discovery = Discovery(central: central, scheduler: clock, isAndroid: false);
    manager = ConnectionManager(
      central: central,
      discovery: discovery,
      scheduler: clock,
      policy: ConnectionPolicy(isAndroid: false),
    );
  });

  tearDown(() async {
    await manager.dispose();
    await discovery.dispose();
    central.dispose();
  });

  Fixture saved(String id, String deviceId, ChannelLayout guess) => Fixture(
    id: id,
    deviceId: deviceId,
    name: id,
    layout: guess,
    driver: DriverKind.electroBright,
    addedAt: DateTime(2026),
  );

  test('every fixture type connects and reports its layout', () async {
    for (final EbFixtureSpec f in EbFixtureCatalog.all) {
      // Saved with a wrong guess: the handshake learns the truth.
      manager.register(
        saved(f.fwsimName, 'dev-${f.fwsimName}', ChannelLayout.rgbw),
      );
    }
    final List<Want> wants = <Want>[
      for (final EbFixtureSpec f in EbFixtureCatalog.all)
        manager.want(f.fwsimName, WantReason.screen),
    ];
    await run(const Duration(seconds: 15));
    for (final EbFixtureSpec f in EbFixtureCatalog.all) {
      final FixtureStatus st = manager.session(f.fwsimName)!.status;
      expect(st.phase, LinkPhase.ready, reason: f.fwsimName);
      expect(st.view!.firmware!.layout, f.layout, reason: f.fwsimName);
      expect(st.view!.firmware!.capabilities.modeMask, f.modeMask);
      expect(st.view!.state.scene.layout, f.layout);
    }
    for (final Want w in wants) {
      w.release();
    }
  });

  test('the original firmware is reported as needing an update', () async {
    manager.register(saved('old', 'dev-legacy', ChannelLayout.rgbw));
    int connects = 0;
    manager.session('old')!.statuses.listen((FixtureStatus x) {
      if (x.phase == LinkPhase.connecting) connects++;
    });
    final Want w = manager.want('old', WantReason.screen);
    await run(const Duration(seconds: 15));
    final FixtureStatus st = manager.session('old')!.status;
    // Tried once, then left alone (no reconnect loop).
    expect(connects, 1);
    // "Try again" (after flashing) connects once more.
    manager.retry('old');
    await run(const Duration(seconds: 5));
    expect(connects, 2);
    expect(manager.session('old')!.status.phase, LinkPhase.incompatible);
    expect(st.phase, LinkPhase.incompatible);
    expect(st.incompatibility, EbIncompatibility.legacyFirmware);
    expect(st.legacyFirmware, isTrue);
    w.release();
  });

  test('discovery hints each light\'s type from its name', () async {
    final ScanLease lease = discovery.acquire(ScanNeed.addFlow);
    await run(const Duration(seconds: 2));
    final Map<String, SeenDevice> seen = <String, SeenDevice>{
      for (final SeenDevice d in discovery.devices) d.id: d,
    };
    for (final EbFixtureSpec f in EbFixtureCatalog.all) {
      final SeenDevice d = seen['dev-${f.fwsimName}']!;
      expect(d.deviceClass, DeviceClass.electroBright);
      expect(EbFixtureCatalog.layoutFromBleName(d.name), f.layout);
    }
    expect(seen['dev-legacy']!.deviceClass, DeviceClass.legacyElectroBright);
    lease.release();
  });
}
