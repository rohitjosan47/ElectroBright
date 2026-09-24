// Adversarial fuzz of the sync engine against the real firmware core:
// random user actions fired without waiting (like fast taps), control passes
// scheduled to create every ingress race, optional injected faults. After
// everything settles the light, the session's confirmed state and the app's
// intent must be identical, and the light must never have seen a malformed
// or unknown command.
@Tags(<String>['fwsim'])
library;

import 'dart:io';
import 'dart:math';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fwsim/eb_harness.dart';
import '../support/fwsim/fwsim_link.dart';

void main() {
  final int seeds =
      int.tryParse(Platform.environment['FUZZ_SEEDS'] ?? '') ?? 25;
  final int from = int.tryParse(Platform.environment['FUZZ_FROM'] ?? '') ?? 1;

  test('schedule fuzz: $seeds seeds x 40 actions converge', () async {
    for (int seed = from; seed < from + seeds; seed++) {
      await _fuzz(seed, faults: false);
    }
  }, timeout: const Timeout(Duration(minutes: 60)));

  test('fault fuzz: $seeds seeds x 40 actions converge', () async {
    for (int seed = from; seed < from + seeds; seed++) {
      await _fuzz(1000 + seed, faults: true);
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}

Future<void> _fuzz(int seed, {required bool faults}) async {
  // ignore: avoid_print
  if (Platform.environment['FUZZ_TRACE'] != null) print('seed $seed');
  final Random r = Random(seed);
  final EbHarness h = await EbHarness.start(
    timing: PassTiming.adversarial,
    seed: seed,
    mtu: r.nextBool() ? 247 : 23,
  );
  final List<String> log = <String>[];
  final List<String> dbg = <String>[];
  h.session.debugLog = dbg.add;
  h.session.commandLane.debugLog = dbg.add;
  final List<Future<Object?>> results = <Future<Object?>>[];
  bool flashFailing = false;
  try {
    for (int i = 0; i < 40; i++) {
      final String action = await _act(h, r, results);
      log.add(action);
      if (faults && r.nextDouble() < 0.18) {
        switch (r.nextInt(3)) {
          case 0:
            await h.link.inject('NFAIL ${1 + r.nextInt(3)}');
            log.add('fault: notify fails');
          case 1:
            // A reply blackout long enough to force a timeout + line reset.
            await h.link.inject('SUB 0');
            await h.wait(Duration(milliseconds: 100 + r.nextInt(1800)));
            await h.link.inject('SUB 1');
            log.add('fault: replies lost');
          default:
            flashFailing = !flashFailing;
            await h.link.inject('KVFAIL ${flashFailing ? 1 : 0}');
            log.add('fault: flash ${flashFailing ? 'failing' : 'ok'}');
        }
      }
      await h.wait(Duration(milliseconds: r.nextInt(r.nextBool() ? 40 : 400)));
    }
    if (flashFailing) await h.link.inject('KVFAIL 0');
    await h.settle(limit: const Duration(minutes: 5));
    // A resync after the dust settles must find nothing to repair.
    await h.run(h.session.resync(full: true));
    await h.settle(limit: const Duration(minutes: 5));
    await h.expectConverged(reason: 'seed $seed');
    // Every action must have finished; a future that never completes is a bug.
    final List<Object?> outcomes = await h.run(
      Future.wait(results),
      limit: const Duration(seconds: 30),
    );
    for (final Object? o in outcomes) {
      final EbResult? res = switch (o) {
        EbResult() => o,
        EbPresetResult() => o.result,
        _ => null,
      };
      if (res == null) continue;
      if (!faults) {
        // Without faults the only legitimate failure is an empty preset slot.
        expect(
          res.isSuccess || res.code == 'PRESET_EMPTY',
          isTrue,
          reason: 'seed $seed: unexpected $res',
        );
      }
    }
    final Map<String, Object?> stats = await h.deviceStats();
    expect(stats['err'], 0, reason: 'seed $seed: malformed command sent');
    expect(stats['unk'], 0, reason: 'seed $seed: unknown command sent');
    if (!faults) {
      expect(stats['ovf'], 0, reason: 'seed $seed: overlong line');
      expect(h.session.divergences, 0, reason: 'seed $seed: divergence');
    }
  } catch (e) {
    // ignore: avoid_print
    print('seed $seed actions:\n  ${log.join('\n  ')}');
    // ignore: avoid_print
    print(
      'events: ${h.events.map((EbEvent e) => e is EbCommandFailed
          ? 'failed ${e.command} ${e.result}'
          : e is EbDivergence
          ? 'diverged ${e.key}'
          : e.runtimeType).join(', ')}',
    );
    // ignore: avoid_print
    print(
      'pending ${h.session.view.pending} lane idle ${h.session.commandLane.isIdle} '
      'timeouts ${h.session.commandLane.timeouts} merged ${h.session.commandLane.merged} '
      'skipped ${h.session.commandLane.skipped} divergences ${h.session.divergences}',
    );
    // ignore: avoid_print
    print(
      'trace (last 60):\n  ${dbg.skip(dbg.length > 60 ? dbg.length - 60 : 0).join('\n  ')}',
    );
    rethrow;
  } finally {
    await h.close();
  }
}

/// Fires one random user action (not awaited, like a UI tap) and returns its
/// description.
Future<String> _act(
  EbHarness h,
  Random r,
  List<Future<Object?>> results,
) async {
  final EbSession s = h.session;
  int level() => 1 + r.nextInt(10);
  int mode() => 1 + r.nextInt(13);
  int slot() => r.nextInt(5);
  ChannelColor rgbw() => ChannelColor.rgbw(
    r.nextInt(256),
    r.nextInt(256),
    r.nextInt(256),
    r.nextInt(256),
  );
  void keep(Future<Object?> f) => results.add(f);

  final int pick = r.nextInt(100);
  if (pick < 14) {
    s.beginGesture(EbKeys.color);
    final int n = 2 + r.nextInt(14);
    for (int i = 0; i < n; i++) {
      s.setColor(rgbw(), live: true);
      await h.wait(Duration(milliseconds: 3 + r.nextInt(20)));
    }
    s.endGesture(EbKeys.color);
    return 'colour drag ($n)';
  }
  if (pick < 24) {
    s.beginGesture(EbKeys.brightness);
    final int n = 2 + r.nextInt(10);
    int b = 0;
    for (int i = 0; i < n; i++) {
      b = r.nextDouble() < 0.15 ? 0 : r.nextInt(256);
      s.setBrightness(b, live: true);
      await h.wait(Duration(milliseconds: 3 + r.nextInt(20)));
    }
    s.endGesture(EbKeys.brightness);
    return 'brightness drag (ends $b)';
  }
  if (pick < 30) {
    final ChannelColor c = rgbw();
    s.setColor(c);
    return 'colour tap $c';
  }
  if (pick < 34) {
    final int b = r.nextDouble() < 0.2 ? 0 : r.nextInt(256);
    s.setBrightness(b);
    return 'brightness tap $b';
  }
  if (pick < 44) {
    final int m = mode();
    keep(s.setMode(m));
    return 'mode $m';
  }
  if (pick < 54) {
    final int m = mode();
    final int v = level();
    keep(r.nextBool() ? s.setSpeed(m, v) : s.setFrequency(m, v));
    return 'slider mode $m = $v';
  }
  if (pick < 58) {
    final EbColorModeKind k =
        EbColorModeKind.values[r.nextInt(EbColorModeKind.values.length)];
    final int v = r.nextInt(2);
    keep(s.setColorMode(k, v));
    return 'colour mode ${k.name} = $v';
  }
  if (pick < 62) {
    final EbPoliceSlot p = EbPoliceSlot.values[r.nextInt(2)];
    keep(s.setPoliceColor(p, rgbw()));
    return 'police ${p.name}';
  }
  if (pick < 70) {
    final bool on = r.nextBool();
    keep(s.setPower(on: on));
    return 'power ${on ? 'on' : 'off'}';
  }
  if (pick < 74) {
    final int t = r.nextDouble() < 0.3 ? 0 : 1 + r.nextInt(3);
    keep(s.setTimer(t));
    return 'timer $t s';
  }
  if (pick < 77) {
    final bool on = r.nextBool();
    keep(s.setSound(on: on));
    return 'sound $on';
  }
  if (pick < 83) {
    final int p = slot();
    keep(s.presetSave(p));
    return 'preset save $p';
  }
  if (pick < 90) {
    final int p = slot();
    keep(s.presetLoad(p));
    return 'preset load $p';
  }
  if (pick < 93) {
    final int p = slot();
    keep(s.presetDelete(p));
    return 'preset delete $p';
  }
  if (pick < 96) {
    keep(s.resync(full: r.nextBool()));
    return 'resync';
  }
  if (pick < 98) {
    keep(s.ping());
    return 'ping';
  }
  if (pick < 99) {
    keep(s.onResume());
    return 'resume';
  }
  keep(s.factoryReset());
  return 'factory reset';
}
