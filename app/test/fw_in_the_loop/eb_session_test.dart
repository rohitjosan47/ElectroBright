// EbSession against the real firmware core (fwsim), one scenario per feature,
// plus regressions for the races that broke the previous app.
@Tags(<String>['fwsim'])
library;

import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_constants.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fwsim/eb_harness.dart';
import '../support/fwsim/fwsim_link.dart';

void main() {
  late EbHarness h;
  tearDown(() => h.close());

  group('handshake', () {
    test('identifies the light and loads its whole state', () async {
      h = await EbHarness.start();
      final EbFirmware fw = h.session.firmware!;
      expect(fw.model, 'EB-C3-RGBW-V1');
      expect(fw.version.version, EbDeviceModel.firmwareVersion);
      expect(fw.modeCount, 13);
      expect(h.session.phase, EbPhase.ready);
      expect(h.view.scene, EbScene.defaults(ChannelLayout.rgbw));
      await h.expectConverged();
    });

    test('retries INFO until notifications are live', () async {
      h = await EbHarness.start(
        subscribeDelay: const Duration(milliseconds: 900),
      );
      expect(h.session.phase, EbPhase.ready);
      await h.settle();
      await h.expectConverged();
    });

    test('works at the minimum MTU (commands split across writes)', () async {
      h = await EbHarness.start(mtu: 23);
      final EbResult r = await h.run(
        h.session.setPoliceColor(
          EbPoliceSlot.a,
          ChannelColor.rgbw(255, 255, 255, 255),
        ),
      );
      expect(r.outcome, EbOutcome.ok);
      await h.settle();
      await h.expectConverged();
    });
  });

  group('colour and brightness', () {
    test('a drag streams frames and lands the final colour reliably', () async {
      h = await EbHarness.start();
      h.session.beginGesture(EbKeys.color);
      for (int i = 0; i < 40; i++) {
        h.session.setColor(
          ChannelColor.rgbw(i * 6, 255 - i * 6, 10, 0),
          live: true,
        );
        await h.wait(const Duration(milliseconds: 7));
      }
      h.session.endGesture(EbKeys.color);
      await h.settle();
      expect(h.view.scene.color, ChannelColor.rgbw(234, 21, 10, 0));
      expect(h.link.writesWithoutResponse, greaterThan(5));
      expect(h.link.writesWithoutResponse, lessThan(40)); // paced, not 1:1
      await h.expectConverged();
    });

    test('lookDelivered completes once the look reached the light', () async {
      h = await EbHarness.start();
      // Nothing outstanding: at once, and nothing is written.
      int writes = h.link.writes;
      await h.run(h.session.lookDelivered());
      expect(h.link.writes, writes);

      // A live frame outstanding: a reliable one follows and completes it.
      final int unreliable = h.link.writesWithoutResponse;
      h.session.beginGesture(EbKeys.color);
      h.session.setColor(ChannelColor.rgbw(9, 8, 7, 6), live: true);
      await h.run(h.session.lookDelivered());
      expect(h.link.writes, writes + 2);
      expect(h.link.writesWithoutResponse, unreliable + 1);
      expect(await h.deviceColor(), ChannelColor.rgbw(9, 8, 7, 6));

      // Its hold is released: later frames still flow.
      writes = h.link.writes;
      h.session.setColor(ChannelColor.rgbw(1, 2, 3, 4), live: true);
      await h.settle();
      expect(h.link.writes, greaterThan(writes));
      expect(await h.deviceColor(), ChannelColor.rgbw(1, 2, 3, 4));
      h.session.endGesture(EbKeys.color);
      await h.settle();
      await h.expectConverged();
    });

    test('lookDelivered sends a refused frame again', () async {
      h = await EbHarness.start();
      h.link.refuseNextWrites = 1;
      h.session.setColor(ChannelColor.rgbw(5, 6, 7, 8));
      await h.run(h.session.lookDelivered());
      expect(h.link.refuseNextWrites, 0);
      expect(await h.deviceColor(), ChannelColor.rgbw(5, 6, 7, 8));
      await h.settle();
      await h.expectConverged();
    });

    test('lookDelivered fails when the link ends', () async {
      h = await EbHarness.start();
      h.session.setColor(ChannelColor.rgbw(5, 6, 7, 8), live: true);
      // The expectation listens before the link goes, so the error is never
      // unhandled whichever microtask completes first.
      final Future<void> failing = expectLater(
        h.session.lookDelivered(),
        throwsA(isA<LinkClosedException>()),
      );
      await h.link.drop();
      await h.run(failing);
    });

    test(
      'frames carry the confirmed brightness, never a stale default',
      () async {
        h = await EbHarness.start();
        h.session.setBrightness(100);
        await h.settle();
        h.session.setColor(ChannelColor.rgbw(1, 2, 3, 4));
        await h.settle();
        final Map<String, Object?> dev = await h.link.deviceState();
        expect((dev['scene']! as Map<String, Object?>)['brightness'], 100);
        await h.expectConverged();
      },
    );

    test(
      'touching brightness wakes a sleeping light; frames alone do not',
      () async {
        h = await EbHarness.start();
        await h.run(h.session.setPower(on: false));
        await h.settle();
        expect(h.view.sleeping, isTrue);
        h.session.beginGesture(EbKeys.brightness);
        h.session.setBrightness(120, live: true);
        await h.wait(const Duration(milliseconds: 30));
        h.session.endGesture(EbKeys.brightness);
        await h.settle();
        expect(h.view.sleeping, isFalse);
        expect(h.view.scene.brightness, 120);
        await h.expectConverged();
      },
    );

    test(
      'releasing brightness at 0 turns the light off and remembers the level',
      () async {
        h = await EbHarness.start();
        h.session.setBrightness(180);
        await h.settle();
        h.session.beginGesture(EbKeys.brightness);
        for (final int b in <int>[140, 90, 40, 0]) {
          h.session.setBrightness(b, live: true);
          await h.wait(const Duration(milliseconds: 30));
        }
        h.session.endGesture(EbKeys.brightness);
        await h.settle();
        expect(h.view.sleeping, isTrue);
        expect(h.view.scene.brightness, 180, reason: 'level kept for power-on');
        await h.expectConverged();
        await h.run(h.session.setPower(on: true));
        await h.settle();
        expect(h.view.sleeping, isFalse);
        expect(h.view.scene.brightness, 180);
        await h.expectConverged();
      },
    );
  });

  group('turning off at zero', () {
    /// Brightness of a binary frame, or null for a text write.
    int? frameBrightness(List<int> w) =>
        w.isNotEmpty && w[0] == 0xAA ? w[w.length - 2] : null;
    bool isSleep(List<int> w) =>
        w.isNotEmpty &&
        w[0] != 0xAA &&
        String.fromCharCodes(w).contains('SLEEP');

    test(
      'release at 0: 0 frame, one SLEEP, the level only after the fade',
      () async {
        h = await EbHarness.start();
        h.session.setBrightness(180);
        await h.settle();
        await h.link.sounds();
        final int from = h.link.written.length;
        // As the brightness pill does it.
        h.session.beginGesture(EbKeys.brightness);
        for (final int b in <int>[140, 90, 40, 0]) {
          h.session.setBrightness(b, live: true);
          await h.wait(const Duration(milliseconds: 30));
        }
        h.session.setBrightness(0);
        h.session.endGesture(EbKeys.brightness);

        // The light, every 5 ms for a second: the output (brightness × the
        // linear 400 ms sleep-fade gain, as RenderEngine renders it) never
        // rises once it is asleep.
        Duration t = Duration.zero;
        Duration? asleepAt;
        double lastOutput = double.infinity;
        while (t < const Duration(seconds: 1)) {
          await h.wait(const Duration(milliseconds: 5));
          t += const Duration(milliseconds: 5);
          final Map<String, Object?> d = await h.link.deviceState();
          final bool asleep = d['sleeping'] == 1;
          final int b =
              (d['scene']! as Map<String, Object?>)['brightness']! as int;
          if (!asleep) continue;
          asleepAt ??= t;
          final double since = (t - asleepAt).inMicroseconds / 1000;
          if (since < Eb.sleepFadeMs) {
            expect(b, 0, reason: 'brightness during the fade (${since}ms)');
          }
          final double gain = (1 - since / Eb.sleepFadeMs).clamp(0.0, 1.0);
          final double output = b / 255 * gain;
          expect(output, lessThanOrEqualTo(lastOutput), reason: '${since}ms');
          lastOutput = output;
        }
        await h.settle();

        // On the wire: the 0 frame before the one SLEEP, nothing brighter
        // for at least the fade after it, then the level for power-on.
        final List<List<int>> writes = h.link.written.sublist(from);
        final List<Duration> at = h.link.writtenAt.sublist(from);
        final List<int> sleeps = <int>[
          for (int i = 0; i < writes.length; i++)
            if (isSleep(writes[i])) i,
        ];
        expect(sleeps, hasLength(1), reason: 'exactly one SLEEP');
        final int sleep = sleeps.single;
        final int lastFrameBefore = <int>[
          for (int i = 0; i < sleep; i++)
            if (frameBrightness(writes[i]) != null) i,
        ].last;
        expect(frameBrightness(writes[lastFrameBefore]), 0);
        final List<int> brighterAfter = <int>[
          for (int i = sleep + 1; i < writes.length; i++)
            if ((frameBrightness(writes[i]) ?? 0) > 0) i,
        ];
        expect(brighterAfter, hasLength(1), reason: 'one restore frame');
        expect(frameBrightness(writes[brighterAfter.single]), 180);
        expect(
          at[brighterAfter.single] - at[sleep],
          greaterThanOrEqualTo(const Duration(milliseconds: Eb.sleepFadeMs)),
        );
        expect(await h.link.sounds(), <String>['Sleep']);
        expect(h.view.sleeping, isTrue);
        expect(h.view.scene.brightness, 180);
        await h.expectConverged();
        // Power on: back at the level from before the drag.
        await h.run(h.session.setPower(on: true));
        await h.settle();
        expect(h.view.sleeping, isFalse);
        expect(h.view.scene.brightness, 180);
        await h.expectConverged();
      },
    );

    test('power on before the level was stored still wakes to it', () async {
      h = await EbHarness.start();
      h.session.setBrightness(120);
      await h.settle();
      h.session.beginGesture(EbKeys.brightness);
      h.session.setBrightness(0, live: true);
      h.session.setBrightness(0);
      h.session.endGesture(EbKeys.brightness);
      await h.wait(const Duration(milliseconds: 150));
      await h.run(h.session.setPower(on: true));
      await h.settle();
      expect(h.view.sleeping, isFalse);
      expect(h.view.scene.brightness, 120);
      await h.expectConverged();
    });
  });

  group('modes and settings', () {
    test('mode, per-mode sliders, colour modes and police colours', () async {
      h = await EbHarness.start();
      expect((await h.run(h.session.setMode(6))).outcome, EbOutcome.ok);
      expect((await h.run(h.session.setSpeed(6, 9))).outcome, EbOutcome.ok);
      expect(
        (await h.run(h.session.setFrequency(11, 2))).outcome,
        EbOutcome.ok,
      );
      await h.run(h.session.setColorMode(EbColorModeKind.club, 1));
      await h.run(
        h.session.setPoliceColor(
          EbPoliceSlot.b,
          ChannelColor.rgbw(0, 0, 40, 255),
        ),
      );
      await h.settle();
      expect(h.view.scene.mode, 6);
      expect(h.view.scene.speeds[5], 9);
      expect(h.view.scene.frequencies[10], 2);
      expect(h.view.scene.speeds[0], 5, reason: 'other modes untouched');
      await h.expectConverged();
    });

    test('selecting the current mode sends nothing (MODE beeps)', () async {
      h = await EbHarness.start();
      await h.run(h.session.setMode(3));
      await h.settle();
      await h.link.sounds();
      final int before = h.link.writes;
      expect((await h.run(h.session.setMode(3))).outcome, EbOutcome.skipped);
      await h.settle();
      expect(h.link.writes, before);
      expect(await h.link.sounds(), isEmpty);
    });

    test('rapid slider moves collapse to the newest value', () async {
      h = await EbHarness.start();
      final List<Future<EbResult>> results = <Future<EbResult>>[
        for (int v = 1; v <= 10; v++) h.session.setSpeed(4, v),
      ];
      await h.settle();
      final List<EbResult> done = await Future.wait(results);
      expect(done.last.outcome, EbOutcome.ok);
      expect(
        done.where((EbResult r) => r.outcome == EbOutcome.superseded),
        isNotEmpty,
      );
      expect(h.view.scene.speeds[3], 10);
      await h.expectConverged();
    });
  });

  group('presets', () {
    test(
      'save captures the latest dragged colour; load restores every slider',
      () async {
        h = await EbHarness.start();
        await h.run(h.session.setMode(8));
        await h.run(h.session.setSpeed(3, 2));
        h.session.beginGesture(EbKeys.color);
        h.session.setColor(ChannelColor.rgbw(10, 20, 30, 40), live: true);
        h.session.setColor(ChannelColor.rgbw(11, 21, 31, 41), live: true);
        h.session.endGesture(EbKeys.color);
        final EbPresetResult saved = await h.run(h.session.presetSave(4));
        expect(saved.result.outcome, EbOutcome.ok);
        expect(saved.scene!.color, ChannelColor.rgbw(11, 21, 31, 41));
        expect(saved.scene!.speeds[2], 2);

        await h.run(h.session.setMode(1));
        await h.run(h.session.setSpeed(3, 7));
        h.session.setColor(ChannelColor.rgbw(255, 0, 0, 0));
        await h.run(h.session.setPower(on: false));
        await h.settle();

        final EbPresetResult loaded = await h.run(h.session.presetLoad(4));
        expect(loaded.result.outcome, EbOutcome.ok);
        expect(loaded.scene, saved.scene);
        await h.settle();
        expect(
          h.view.sleeping,
          isFalse,
          reason: 'loading a preset wakes the light',
        );
        expect(h.view.scene.speeds[2], 2, reason: 'all 13 pairs re-read');
        expect(h.view.presets, <int>{4});
        await h.expectConverged();
      },
    );

    test(
      'loading an empty slot fails cleanly and drops it from the list',
      () async {
        h = await EbHarness.start();
        final EbPresetResult r = await h.run(h.session.presetLoad(9));
        expect(r.result.outcome, EbOutcome.failed);
        expect(r.result.code, 'PRESET_EMPTY');
        await h.settle();
        await h.expectConverged();
      },
    );

    test('delete', () async {
      h = await EbHarness.start();
      await h.run(h.session.presetSave(0));
      await h.run(h.session.presetSave(14)); // the last of 15
      expect((await h.run(h.session.presetDelete(0))).outcome, EbOutcome.ok);
      await h.settle();
      expect(h.view.presets, <int>{14});
      await h.expectConverged();
    });
  });

  group('power, timer, sound, reset', () {
    test('timer expiry turns the light off and is reported', () async {
      h = await EbHarness.start();
      await h.run(h.session.setTimer(2));
      expect(h.view.timerDeadline, isNotNull);
      await h.wait(const Duration(milliseconds: 2300));
      await h.settle();
      expect(h.view.sleeping, isTrue);
      expect(h.view.timerDeadline, isNull);
      expect(h.events.whereType<EbTimerExpired>(), hasLength(1));
      await h.expectConverged();
    });

    test('a missed expiry push is recovered by asking the light', () async {
      h = await EbHarness.start();
      await h.run(h.session.setTimer(1));
      await h.link.inject('SUB 0'); // app "suspended": the push is lost
      await h.wait(const Duration(milliseconds: 1500));
      await h.link.inject('SUB 1');
      await h.settle(atLeast: const Duration(seconds: 4));
      expect(h.view.sleeping, isTrue);
      await h.expectConverged();
    });

    test('SLEEP cancels the timer; WAKE brings the light back', () async {
      h = await EbHarness.start();
      await h.run(h.session.setTimer(600));
      await h.run(h.session.setPower(on: false));
      await h.settle();
      expect(h.view.timerDeadline, isNull);
      await h.run(h.session.setPower(on: true));
      await h.settle();
      await h.expectConverged();
    });

    test('sound toggles; a flash failure is a warning, not an error', () async {
      h = await EbHarness.start(deviceSetup: const <String>['KVFAIL 1']);
      final EbResult r = await h.run(h.session.setSound(on: false));
      expect(r.outcome, EbOutcome.ok);
      expect(h.events.whereType<EbStorageWarning>(), isNotEmpty);
      await h.settle();
      await h.expectConverged();
    });

    test('a preset save that cannot be written fails with STORAGE', () async {
      h = await EbHarness.start(deviceSetup: const <String>['KVFAIL 1']);
      final EbPresetResult r = await h.run(h.session.presetSave(2));
      expect(r.result.outcome, EbOutcome.failed);
      expect(r.result.code, 'STORAGE');
      await h.settle();
      await h.expectConverged();
    });

    test('factory reset restores defaults and re-reads everything', () async {
      h = await EbHarness.start();
      await h.run(h.session.setMode(9));
      await h.run(h.session.presetSave(1));
      await h.run(h.session.setSound(on: false));
      expect((await h.run(h.session.factoryReset())).outcome, EbOutcome.ok);
      await h.settle();
      expect(h.view.scene, EbScene.defaults(ChannelLayout.rgbw));
      expect(h.view.presets, isEmpty);
      expect(h.view.soundOn, isTrue);
      await h.expectConverged();
    });
  });

  group('robustness', () {
    test('a lost reply times out, resets the line and retries', () async {
      h = await EbHarness.start();
      await h.link.inject('SUB 0'); // the first reply vanishes
      final Future<EbResult> r = h.session.setMode(5);
      await h.wait(const Duration(milliseconds: 200));
      await h.link.inject('SUB 1'); // back before the 1.5 s timeout and resend
      expect((await h.run(r)).outcome, EbOutcome.ok);
      await h.settle();
      await h.expectConverged();
      final Map<String, Object?> stats = await h.deviceStats();
      expect(stats['err'], 0);
      expect(stats['unk'], 0);
      expect(stats['rej'], 1, reason: 'exactly one line reset');
      expect(h.session.commandLane.timeouts, 1);
    });

    test('the link dropping mid-command reports disconnected', () async {
      h = await EbHarness.start();
      await h.link.inject('SUB 0');
      final Future<EbResult> r = h.session.setMode(4);
      await h.wait(const Duration(milliseconds: 100));
      await h.link.drop();
      expect((await h.run(r)).outcome, EbOutcome.disconnected);
      expect(h.session.phase, EbPhase.closed);
    });

    test(
      'regression M1: a STATUS in flight never reverts a newer change',
      () async {
        h = await EbHarness.start(timing: PassTiming.adversarial, seed: 3);
        final Future<void> resync = h.session.resync();
        final Future<EbResult> mode = h.session.setMode(12);
        final Future<EbResult> speed = h.session.setSpeed(12, 3);
        // The UI must never show the old mode while all this is in flight.
        final List<int> seen = <int>[];
        final sub = h.session.views.listen(
          (EbView v) => seen.add(v.state.scene.mode),
        );
        await h.run(Future.wait(<Future<Object?>>[resync, mode, speed]));
        await h.settle();
        await sub.cancel();
        expect(seen.where((int m) => m != 12), isEmpty);
        await h.expectConverged();
      },
    );

    test(
      'regression M5: a timer push racing a preset load is told apart',
      () async {
        h = await EbHarness.start();
        await h.run(h.session.presetSave(2));
        await h.run(h.session.setTimer(1));
        await h.wait(const Duration(milliseconds: 960));
        final EbPresetResult r = await h.run(h.session.presetLoad(2));
        expect(r.result.outcome, EbOutcome.ok);
        await h.settle();
        await h.expectConverged();
      },
    );
  });
}
