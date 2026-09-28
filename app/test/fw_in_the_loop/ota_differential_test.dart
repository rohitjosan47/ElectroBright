// The Dart firmware twin's wireless-update service (lib/sim/ota_twin.dart)
// must behave exactly like the real firmware core (fwsim): the same control
// notifications, NUS replies and state (transfer, slots, rollback) for full
// transfers, dropouts and resumes, duplicates, gaps, overflowing writes,
// every error, timeouts, restarts, the first-boot self-check and busy
// commands, under random scripts.
@Tags(<String>['fwsim'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_ota.dart';
import 'package:electrobright/core/util/sha256.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/ota_twin.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fwsim/fwsim_process.dart';

const DeepCollectionEquality _deep = DeepCollectionEquality();

/// A fake firmware image: the ESP image magic, the identity block at 0x120
/// (where the linker puts it), pseudo-random bytes.
Uint8List otaImage(
  int size, {
  String version = '3.9.0',
  int seed = 1,
  String? product,
}) {
  final Random r = Random(seed);
  final Uint8List img = Uint8List(size);
  for (int i = 0; i < size; i++) {
    img[i] = r.nextInt(256);
  }
  if (size > 0) img[0] = 0xE9;
  if (size >= 0x120 + ImageIdentityTwin.size) {
    img.setAll(
      0x120,
      ImageIdentityTwin.build(
        version: version,
        productName: product ?? ImageIdentityTwin.product,
      ),
    );
  }
  return img;
}

List<int> _le32(int v) => <int>[
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];
List<int> _le16(int v) => <int>[v & 0xFF, (v >> 8) & 0xFF];

List<int> beginRequest(
  Uint8List img,
  List<int> version, {
  bool reinstall = false,
  bool wrongHash = false,
}) {
  final Uint8List hash = Sha256.of(img);
  if (wrongHash) hash[0] ^= 0xFF;
  return <int>[
    EbOta.begin,
    ..._le32(img.length),
    ...hash,
    for (final int v in version) ..._le16(v),
    if (reinstall) EbOta.flagReinstall else 0,
  ];
}

List<int> dataWrite(Uint8List img, int offset, int len) => <int>[
  ..._le32(offset),
  ...img.sublist(offset, min(img.length, offset + len)),
];

String _hex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

void main() {
  final int seeds =
      int.tryParse(Platform.environment['FWSIM_SEEDS'] ?? '') ?? 12;

  test('Sha256 matches the known vectors', () {
    expect(
      _hex(Sha256.of(utf8.encode('abc'))),
      'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
    );
    expect(
      _hex(Sha256.of(const <int>[])),
      'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
    );
    final Sha256 s = Sha256()..update(utf8.encode('ab'));
    s.digest();
    s.update(utf8.encode('c'));
    expect(_hex(s.digest()), _hex(Sha256.of(utf8.encode('abc'))));
  });

  for (final EbFixtureSpec fixture in <EbFixtureSpec>[
    EbFixtureCatalog.rgbw,
    EbFixtureCatalog.cct,
  ]) {
    test('${fixture.layout.wire}: update service of the twin matches fwsim '
        'on $seeds random scripts', () async {
      final Map<String, int> seen = <String, int>{};
      for (int seed = 1; seed <= seeds; seed++) {
        final FwSim sim = await FwSim.start(fixture: fixture.fwsimName);
        try {
          await _runSeed(sim, fixture, seed, seen);
        } catch (e) {
          final String path = await sim.saveTranscript(
            'ota_diff_${fixture.fwsimName}_$seed',
            header: 'seed $seed: $e',
          );
          fail('seed $seed: $e\ntranscript: $path');
        } finally {
          await sim.close();
        }
      }
      // The scripts reached every outcome worth comparing.
      for (final String what in <String>[
        'endOk',
        'resumed',
        'restart',
        'confirmed',
        'rolledBack',
        'error ${EbOtaError.hashMismatch.code}',
        'error ${EbOtaError.notElectroBright.code}',
        'error ${EbOtaError.downgrade.code}',
        'error ${EbOtaError.busy.code}',
        'error ${EbOtaError.timeout.code}',
        'error ${EbOtaError.incomplete.code}',
      ]) {
        expect(
          seen[what] ?? 0,
          greaterThan(0),
          reason: '$what never happened: $seen',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

Future<void> _runSeed(
  FwSim sim,
  EbFixtureSpec fixture,
  int seed,
  Map<String, int> seen,
) async {
  void count(String what) => seen[what] = (seen[what] ?? 0) + 1;
  final Random rnd = Random(seed);
  final EbDeviceModel model = EbDeviceModel(fixture: fixture)..takeSounds();
  await sim.request('AUTO 0');

  final List<Uint8List> images = <Uint8List>[
    otaImage(30000 + rnd.nextInt(30000), seed: seed),
    otaImage(20000, version: '3.9.1', seed: seed + 100),
    otaImage(9000, version: '3.8.0', seed: seed + 200), // reinstall
    otaImage(9000, seed: seed + 300, product: 'Espressif'),
    otaImage(9000, version: '3.7.0', seed: seed + 400), // downgrade
  ];
  final List<List<int>> versions = <List<int>>[
    <int>[3, 9, 0],
    <int>[3, 9, 1],
    <int>[3, 8, 0],
    <int>[3, 9, 0],
    <int>[3, 7, 0],
  ];
  int current = 0;
  int sent = 0; // the app's idea of where it is
  int lastRestarts = 0;
  bool wasPending = false;

  Future<void> both(String request, void Function() twin) async {
    final FwSimReply r = await sim.request(request);
    twin();
    final List<String> wantN = r.notifications.map(_hex).toList();
    final List<String> gotN = model.takeNotifications().map(_hex).toList();
    final List<String> wantO = r.otaNotifications.map(_hex).toList();
    final List<String> gotO = model.takeOtaNotifications().map(_hex).toList();
    if (!_deep.equals(wantN, gotN) || !_deep.equals(wantO, gotO)) {
      throw StateError(
        'after "$request": notifications differ\n'
        '  fwsim N $wantN O $wantO\n  model N $gotN O $gotO',
      );
    }
    for (final Uint8List o in r.otaNotifications) {
      if (o[0] == EbOta.ack || o[0] == EbOta.beginOk) {
        sent = o[1] | (o[2] << 8) | (o[3] << 16) | (o[4] << 24);
        if (o[0] == EbOta.beginOk && sent > 0) count('resumed');
      }
      if (o[0] == EbOta.endOk) count('endOk');
      if (o[0] == EbOta.error) count('error ${o[1]}');
    }
    final int restarts = model.restarts;
    if (restarts > lastRestarts) count('restart');
    lastRestarts = restarts;
  }

  Future<void> compareState(String when) async {
    final Map<String, Object?> want = await sim.state();
    final Object? got = jsonDecode(jsonEncode(model.state()));
    if (!_deep.equals(want, got)) {
      throw StateError('state differs $when\n  fwsim: $want\n  model: $got');
    }
    final Map<String, Object?> o = want['ota']! as Map<String, Object?>;
    if (o['rolledBack'] == 1) count('rolledBack');
    if (wasPending && o['pending'] == 0 && o['rolledBack'] == 0) {
      count('confirmed');
    }
    wasPending = o['pending'] == 1;
  }

  Future<void> connect() async {
    await both('CONNECT', model.connect);
    await both('MTU 517', () => model.setMtu(517));
    await both('SUB 1', () => model.setSubscribed(subscribed: true));
    await both('OSUB 1', () => model.setOtaSubscribed(subscribed: true));
    await both('PASS', model.pass);
  }

  Future<void> control(List<int> m) async {
    await both('OC ${_hex(m)}', () => model.otaControl(m));
    await both('PASS', model.pass);
  }

  Future<void> data(List<int> m) =>
      both('OD ${_hex(m)}', () => model.otaData(m));

  await connect();
  for (int op = 0; op < 160; op++) {
    final Uint8List img = images[current];
    // A finished image is usually ENDed next, as the app would.
    final bool complete = model.ota.active && sent >= img.length;
    final int x = complete && rnd.nextInt(10) < 7 ? 56 : rnd.nextInt(100);
    if (x < 8) {
      current = rnd.nextInt(10) < 7 ? 0 : rnd.nextInt(images.length);
      await control(
        beginRequest(
          images[current],
          versions[current],
          reinstall: current == 2 || rnd.nextInt(10) == 0,
          wrongHash: rnd.nextInt(5) == 0,
        ),
      );
    } else if (x < 55) {
      // A window from where the app thinks it is, sometimes with a
      // duplicate, a skipped chunk or more than fits.
      final int chunk = 200 + rnd.nextInt(310);
      final int windowEnd = min(
        img.length,
        (sent ~/ EbOta.window + 1 + (rnd.nextInt(8) == 0 ? 2 : 0)) *
            EbOta.window,
      );
      for (int off = sent; off < windowEnd; off += chunk) {
        if (rnd.nextInt(40) == 0) continue; // lost in the air
        await data(dataWrite(img, off, chunk));
        if (rnd.nextInt(30) == 0) await data(dataWrite(img, off, chunk));
      }
      await both('PASS', model.pass);
    } else if (x < 62) {
      await control(<int>[EbOta.end]);
    } else if (x < 65) {
      await control(<int>[EbOta.abort]);
    } else if (x < 70) {
      await control(<int>[EbOta.status]);
    } else if (x < 72) {
      await control(<int>[0x7F, 1]);
    } else if (x < 78) {
      final int ms = <int>[500, 3000, 16000][rnd.nextInt(3)];
      await both('ADV $ms', () => model.advance(ms));
    } else if (x < 83) {
      final String line = <String>[
        'STATUS',
        'MODE:2',
        'DIAG',
        'IDENTIFY',
        'PROBE:1:1',
      ][rnd.nextInt(5)];
      final List<int> bytes = utf8.encode('$line\n');
      await both('W ${_hex(bytes)}', () => model.write(bytes));
      await both('PASS', model.pass);
    } else if (x < 87) {
      await both('DISCONNECT', model.disconnect);
      await both('PASS', model.pass);
      final int away = rnd.nextInt(3) * 2000 + 50;
      await both('ADV $away', () => model.advance(away));
      await connect();
    } else if (x < 89) {
      await both('REBOOT', () {
        model
          ..reboot()
          ..takeSounds();
      });
      await connect();
    } else if (x < 91) {
      final bool on = rnd.nextInt(4) == 0;
      await both(
        'OTA fail ${on ? 1 : 0}',
        () => model.otaFlash.failWrites = on,
      );
    } else if (x < 93) {
      final bool on = rnd.nextInt(4) == 0;
      await both(
        'OTA invalid ${on ? 1 : 0}',
        () => model.otaFlash.forceInvalid = on,
      );
    } else {
      if (!model.connected) await connect();
    }
    await compareState('after op $op (seed $seed)');
    if (!model.connected) await connect();
  }
}
