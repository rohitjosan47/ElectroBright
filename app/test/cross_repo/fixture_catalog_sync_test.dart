import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_reply.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firmware_sources.dart';

/// The app's fixture catalogue (EbFixtureCatalog) must equal the firmware's
/// fixtures: identity, layout, defaults, supported modes and legacy frames of
/// every firmware/fixtures/*/Fixture.h, and the layout table of
/// ChannelLayout.h. A fixture added to the firmware fails here until the app
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
    test('${fw.folder}: catalogue entry equals Fixture.h', () {
      final EbFixtureSpec spec = EbFixtureCatalog.all.firstWhere(
        (EbFixtureSpec s) => s.fwsimName == fw.name,
      );
      final String src = fw.source;
      String str(String name) =>
          RegExp('constexpr const char\\* $name = "([^"]*)";')
              .firstMatch(src)!
              .group(1)!;

      expect(spec.folder, fw.folder);
      expect(str('kDeviceName'), spec.bleName);
      expect(str('kModelId'), spec.modelId);
      expect(str('kCapsReply'), spec.capsReply);
      expect(str('kNvsNamespace'), spec.nvsNamespace);

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

      // Supported modes: CAPS MODES= (absent = all 13).
      final EbCaps caps = parseEbReply(spec.capsReply) as EbCaps;
      expect(caps.modesMask ?? 0x1FFF, spec.modeMask);
    });
  }

  test('the Dart firmware twin reports each fixture\'s identity', () {
    for (final EbFixtureSpec spec in EbFixtureCatalog.all) {
      final EbDeviceModel m = EbDeviceModel(fixture: spec);
      expect(m.modelId, spec.modelId);
      expect(m.capsReply, spec.capsReply);
    }
  });
}
