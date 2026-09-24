// EbSession against the real firmware core (fwsim) for every fixture of the
// family: the handshake learns the layout and capabilities, and every intent
// speaks that layout (n-value colours, frames, police colours, presets,
// factory defaults, unsupported modes).
@Tags(<String>['fwsim'])
library;

import 'dart:math';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/fwsim/eb_harness.dart';
import '../support/fwsim/fwsim_link.dart';

void main() {
  late EbHarness h;
  tearDown(() => h.close());

  for (final EbFixtureSpec fixture in fixturesUnderTest()) {
    final ChannelLayout layout = fixture.layout;
    ChannelColor colour(int seed) {
      final Random r = Random(seed);
      return ChannelColor(layout, <int>[
        for (int i = 0; i < layout.n; i++) r.nextInt(256),
      ]);
    }

    group('${layout.wire} fixture', () {
      test('the handshake learns the layout and capabilities', () async {
        h = await EbHarness.start(fixture: fixture);
        final EbFirmware fw = h.session.firmware!;
        expect(fw.model, fixture.modelId);
        expect(fw.layout, layout);
        expect(h.session.layout, layout);
        expect(fw.capabilities.modeMask, fixture.modeMask);
        expect(h.view.scene, EbScene.defaults(layout));
        await h.expectConverged();
      });

      test(
        'a drag streams n-channel frames and lands the final colour',
        () async {
          h = await EbHarness.start(
            fixture: fixture,
            timing: PassTiming.adversarial,
          );
          h.session.beginGesture(EbKeys.color);
          for (int i = 0; i < 30; i++) {
            h.session.setColor(colour(i), live: true);
            await h.wait(const Duration(milliseconds: 20));
          }
          h.session.endGesture(EbKeys.color);
          h.session.setColor(colour(999));
          await h.settle();
          expect(h.session.confirmed.scene.color, colour(999));
          expect((await h.deviceStats())['binbad'], 0);
          await h.expectConverged();
        },
      );

      test('setLook moves colour and brightness in one frame', () async {
        h = await EbHarness.start(fixture: fixture);
        h.session.setLook(color: colour(7), brightness: 77);
        await h.settle();
        expect(h.session.confirmed.scene.color, colour(7));
        expect(h.session.confirmed.scene.brightness, 77);
        await h.expectConverged();
      });

      test('police colours carry one value per channel', () async {
        h = await EbHarness.start(fixture: fixture, mtu: 23);
        final EbResult a = await h.run(
          h.session.setPoliceColor(EbPoliceSlot.a, colour(1)),
        );
        final EbResult b = await h.run(
          h.session.setPoliceColor(EbPoliceSlot.b, colour(2)),
        );
        expect(a.outcome, EbOutcome.ok);
        expect(b.outcome, EbOutcome.ok);
        await h.settle();
        await h.expectConverged();
      });

      test('a colour of another layout is refused locally', () async {
        h = await EbHarness.start(fixture: fixture);
        final ChannelLayout other = ChannelLayout.values.firstWhere(
          (ChannelLayout l) => l != layout,
        );
        expect(
          () => h.session.setColor(ChannelColor.black(other)),
          throwsArgumentError,
        );
      });

      test('presets save and load the layout\'s colours', () async {
        h = await EbHarness.start(fixture: fixture);
        h.session.setColor(colour(11));
        await h.settle();
        expect((await h.run(h.session.presetSave(3))).result.isSuccess, isTrue);
        h.session.setColor(colour(12));
        await h.settle();
        final EbPresetResult load = await h.run(h.session.presetLoad(3));
        expect(load.result.isSuccess, isTrue);
        expect(load.scene!.color, colour(11));
        await h.settle();
        await h.expectConverged();
      });

      test('factory reset returns the fixture\'s own defaults', () async {
        h = await EbHarness.start(fixture: fixture);
        h.session.setColor(colour(21));
        await h.run(h.session.setPoliceColor(EbPoliceSlot.b, colour(22)));
        await h.settle();
        expect((await h.run(h.session.factoryReset())).isSuccess, isTrue);
        await h.settle();
        expect(h.view.scene, EbScene.defaults(layout));
        await h.expectConverged();
      });

      test('every supported mode works; others are never sent', () async {
        h = await EbHarness.start(fixture: fixture);
        for (int m = 1; m <= 13; m++) {
          final EbResult r = await h.run(h.session.setMode(m));
          if (fixture.modeMask >> (m - 1) & 1 == 1) {
            expect(r.isSuccess, isTrue, reason: 'mode $m');
          } else {
            expect(r.code, 'MODE_UNSUPPORTED', reason: 'mode $m');
            expect(
              (await h.run(h.session.setSpeed(m, 3))).code,
              'MODE_UNSUPPORTED',
            );
          }
        }
        await h.settle();
        // Nothing the light had to reject.
        expect((await h.deviceStats())['err'], 0);
        await h.expectConverged();
      });
    });
  }
}
