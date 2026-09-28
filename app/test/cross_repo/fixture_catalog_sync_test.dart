import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_reply.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firmware_sources.dart';

/// The app's fixture catalogue (EbFixtureCatalog) must equal the firmware's
/// fixture types: identity, layout, defaults, supported modes, CAPS and legacy
/// frames of every entry of the core's profile table (fixture/Profiles.h), the
/// sketch that makes it a new light's default, and the layout table of
/// ChannelLayout.h. A type added to the firmware fails here until the app
/// knows it.
void main() {
  final List<FirmwareFixture> firmware = firmwareFixtureList();

  test('the app knows exactly the firmware\'s fixtures', () {
    expect(
      firmware.map((FirmwareFixture f) => f.name).toSet(),
      EbFixtureCatalog.all.map((EbFixtureSpec f) => f.fwsimName).toSet(),
    );
  });

  test('channel layouts match ChannelLayout.h', () {
    final String src = readFirmware('fixture/ChannelLayout.h');
    final RegExp row = RegExp(
      r'inline constexpr ChannelLayout k\w+\{"(\w+)", (\d), \{([^}]*)\}',
    );
    final Map<String, List<String>> rows = <String, List<String>>{
      for (final RegExpMatch m in row.allMatches(src))
        m.group(1)!: m
            .group(3)!
            .split(',')
            .map(
              (String r) =>
                  r.trim().replaceFirst('Channel::', '').toLowerCase(),
            )
            .toList(),
    };
    // NONE is setup-needed mode (no LEDs, no modes), not a fixture layout.
    expect(src, contains('ChannelLayout kNone{"NONE", 0, {}, 0};'));
    rows.remove('NONE');
    expect(
      rows.keys.toSet(),
      ChannelLayout.values.map((ChannelLayout l) => l.wire).toSet(),
    );
    for (final ChannelLayout l in ChannelLayout.values) {
      expect(
        rows[l.wire],
        l.roles.map((ChannelRole r) => r.name).toList(),
        reason: l.wire,
      );
    }
  });

  for (final FirmwareFixture fw in firmware) {
    test('${fw.name}: catalogue entry equals the profile table', () {
      final EbFixtureSpec spec = EbFixtureCatalog.all.firstWhere(
        (EbFixtureSpec s) => s.fwsimName == fw.name,
      );
      final String src = fw.source;
      final List<String> strings = profileStrings(src);

      expect(spec.folder, fw.folder);
      expect(strings[0], spec.modelId);
      expect(strings[1], spec.bleName);
      expect(
        spec.capsReply,
        firmwareCaps(spec.layout.wire, firmwareModeMask(spec.layout.wire)),
      );

      // &layouts::kRgbcct -> RGBCCT
      final String layoutRef = RegExp(r'&layouts::k(\w+),')
          .firstMatch(src)!
          .group(1)!;
      expect(layoutRef.toUpperCase(), spec.layout.wire);

      // Scene defaults {{colour}, {police A}, {police B}} in the firmware's
      // five colour slots r, g, b, w (= W or CW), ww.
      final RegExpMatch d = RegExp(r'\{\{([^}]*)\}, \{([^}]*)\}, \{([^}]*)\}\}')
          .firstMatch(src)!;
      ChannelColor project(String slots) {
        final List<int> v = slots
            .split(',')
            .map((String x) => int.parse(x.trim()))
            .toList();
        while (v.length < 5) {
          v.add(0);
        }
        int slot(ChannelRole r) => switch (r) {
          ChannelRole.r => v[0],
          ChannelRole.g => v[1],
          ChannelRole.b => v[2],
          ChannelRole.w || ChannelRole.cw => v[3],
          ChannelRole.ww => v[4],
        };
        return ChannelColor(spec.layout, <int>[
          for (final ChannelRole r in spec.layout.roles) slot(r),
        ]);
      }

      expect(project(d.group(1)!), spec.color);
      expect(project(d.group(2)!), spec.policeA);
      expect(project(d.group(3)!), spec.policeB);

      // legacyFrames: the last field of kProfile.
      final String legacy = RegExp(r'(true|false),\s*(?://[^\n]*)?\n\};')
          .firstMatch(src)!
          .group(1)!;
      expect(legacy == 'true', spec.legacyFrames);

      // Supported modes: ChannelLayout.h, announced as CAPS MODES= (absent =
      // all 13).
      expect(spec.modeMask, firmwareModeMask(spec.layout.wire));
      final EbCaps caps = parseEbReply(spec.capsReply) as EbCaps;
      expect(caps.modesMask ?? 0x1FFF, spec.modeMask);
      expect(caps.types, firmwareTypes());
      expect(caps.probe, isTrue);
    });
  }

  test('TYPES= lists the catalogue in order', () {
    expect(
      firmwareTypes(),
      EbFixtureCatalog.all.map((EbFixtureSpec f) => f.layout.wire).toList(),
    );
  });

  test(
    'the Dart firmware twin\'s setup-needed mode equals profiles::kNone',
    () {
      final List<String> strings = profileStrings(profileSource('None'));
      const EbFixtureSpec setup = EbDeviceModel.setupSpec;
      expect(strings[0], setup.modelId);
      expect(strings[1], setup.bleName);
      expect(setup.capsReply, firmwareCaps('NONE', 0));
      expect((parseEbReply(setup.capsReply) as EbCaps).setupNeeded, isTrue);
      final EbDeviceModel m = EbDeviceModel(fixture: null);
      expect(m.setupNeeded, isTrue);
      expect(m.fixture.capsReply, setup.capsReply);
    },
  );

  test('the Dart firmware twin reports each fixture\'s identity', () {
    for (final EbFixtureSpec spec in EbFixtureCatalog.all) {
      final EbDeviceModel m = EbDeviceModel(fixture: spec);
      expect(m.modelId, spec.modelId);
      expect(m.capsReply, spec.capsReply);
    }
  });
}
