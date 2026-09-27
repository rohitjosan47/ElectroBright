import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/light_capabilities.dart';
import 'package:electrobright/core/protocol/eb/eb_constants.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_frame.dart';
import 'package:electrobright/core/protocol/eb/eb_identity.dart';
import 'package:electrobright/core/protocol/eb/eb_reply.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout-native protocol (docs/protocol.md §2-§5) for every fixture.
void main() {
  group('ChannelLayout', () {
    test('widths, salts and STATUS sizes match docs/protocol.md', () {
      // layout: (n, frame length, salt, STATUS fields)
      const Map<ChannelLayout, (int, int, int, int)> expected =
          <ChannelLayout, (int, int, int, int)>{
            ChannelLayout.rgbw: (4, 8, 0x55, 23),
            ChannelLayout.rgb: (3, 7, 0x56, 20),
            ChannelLayout.rgbcct: (5, 9, 0x50, 26),
            ChannelLayout.cct: (2, 6, 0x57, 17),
            ChannelLayout.w: (1, 5, 0x54, 14),
          };
      for (final MapEntry<ChannelLayout, (int, int, int, int)> e
          in expected.entries) {
        final ChannelLayout l = e.key;
        expect(
          (l.n, l.frameLength, l.salt, l.statusFields),
          e.value,
          reason: l.wire,
        );
        expect(ChannelLayout.fromWire(l.wire), l);
        expect(ChannelLayout.fromStatusFieldCount(l.statusFields), l);
      }
      expect(ChannelLayout.fromWire('RGBWW'), isNull);
    });

    test('colour and white capabilities follow the LEDs', () {
      expect(ChannelLayout.rgb.hasColour, isTrue);
      expect(ChannelLayout.cct.hasColour, isFalse);
      expect(ChannelLayout.rgb.white, WhiteKind.none);
      expect(ChannelLayout.rgbw.white, WhiteKind.single);
      expect(ChannelLayout.w.white, WhiteKind.single);
      expect(ChannelLayout.cct.white, WhiteKind.tunable);
      expect(ChannelLayout.rgbcct.white, WhiteKind.tunable);
      expect(
        ChannelLayout.values.where((ChannelLayout l) => l.acceptsRgbwAlias),
        <ChannelLayout>[ChannelLayout.rgbw],
      );
      expect(
        <ColourSurface>[
          for (final ChannelLayout l in ChannelLayout.values)
            LightCapabilities.assumed(l).colourSurface,
        ],
        <ColourSurface>[
          ColourSurface.intensity,
          ColourSurface.tunableWhite,
          ColourSurface.colour,
          ColourSurface.colourPlusWhite,
          ColourSurface.colourPlusTunableWhite,
        ],
      );
    });
  });

  group('ChannelColor', () {
    test('needs exactly one 0..255 value per channel', () {
      expect(
        () => ChannelColor(ChannelLayout.cct, <int>[1]),
        throwsArgumentError,
      );
      expect(
        () => ChannelColor(ChannelLayout.cct, <int>[1, 256]),
        throwsArgumentError,
      );
      final ChannelColor c = ChannelColor(ChannelLayout.rgbcct, <int>[
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(c.values, <int>[1, 2, 3, 4, 5]);
      expect(c.role(ChannelRole.ww), 5);
      expect(c.role(ChannelRole.w), 0);
      expect(c.maxChannel, 5);
      expect(c.withRole(ChannelRole.cw, 9).values, <int>[1, 2, 3, 9, 5]);
    });

    test('equality includes the layout', () {
      expect(
        ChannelColor(ChannelLayout.w, <int>[7]),
        ChannelColor(ChannelLayout.w, <int>[7]),
      );
      expect(
        ChannelColor(ChannelLayout.rgb, <int>[0, 0, 0]),
        isNot(ChannelColor.black(ChannelLayout.rgbw)),
      );
      expect(ChannelColor.black(ChannelLayout.cct).isBlack, isTrue);
    });

    test('roles() rejects channels the layout lacks', () {
      expect(
        ChannelColor.roles(ChannelLayout.cct, cw: 10, ww: 20).values,
        <int>[10, 20],
      );
      expect(
        () => ChannelColor.roles(ChannelLayout.cct, r: 1),
        throwsArgumentError,
      );
    });

    test('JSON is strict', () {
      final ChannelColor c = ChannelColor(ChannelLayout.rgb, <int>[1, 2, 3]);
      expect(ChannelColor.fromJson(ChannelLayout.rgb, c.toJson()), c);
      expect(ChannelColor.fromJson(ChannelLayout.rgbw, c.toJson()), isNull);
      expect(
        ChannelColor.fromJson(ChannelLayout.rgb, <Object>[1, 2, 'x']),
        isNull,
      );
    });
  });

  group('STATUS and frames per layout', () {
    // docs/protocol.md §5 factory-default examples.
    const Map<ChannelLayout, String> defaults = <ChannelLayout, String>{
      ChannelLayout.rgbw:
          'STATUS:255,255,255,0,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,255',
      ChannelLayout.rgb:
          'STATUS:255,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,255,255,255',
      ChannelLayout.rgbcct: 'STATUS:0,0,0,255,255,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,0,255,255',
      ChannelLayout.cct: 'STATUS:255,255,255,1,5,5,0,0,1,0,0,0,1,0,255,255,0',
      ChannelLayout.w: 'STATUS:255,255,1,5,5,0,0,1,0,0,0,1,255,255',
    };

    test('every default STATUS parses to that fixture\'s defaults', () {
      for (final MapEntry<ChannelLayout, String> e in defaults.entries) {
        final EbReply r = parseEbReply(e.value, layout: e.key);
        expect(r, isA<EbStatusReply>(), reason: e.key.wire);
        final EbStatus st = (r as EbStatusReply).status;
        expect(
          st.applyTo(EbScene.defaults(e.key)),
          EbScene.defaults(e.key),
          reason: e.key.wire,
        );
        // Without a layout the field count identifies it.
        expect(parseEbReply(e.value), isA<EbStatusReply>());
      }
    });

    test('a STATUS of another layout is malformed', () {
      expect(
        parseEbReply(defaults[ChannelLayout.rgbw]!, layout: ChannelLayout.cct),
        isA<EbMalformed>(),
      );
    });

    test('frames are n + 4 bytes with the layout salt', () {
      // docs/protocol.md §3: [AA, seq, c1..cn, Br, seq^c..^Br^salt]
      expect(
        EbFrame.encode(4, ChannelColor(ChannelLayout.w, <int>[90]), 200),
        <int>[0xAA, 4, 90, 200, 4 ^ 90 ^ 200 ^ 0x54],
      );
      expect(
        EbFrame.encode(3, ChannelColor(ChannelLayout.cct, <int>[40, 200]), 99),
        <int>[0xAA, 3, 40, 200, 99, 3 ^ 40 ^ 200 ^ 99 ^ 0x57],
      );
      expect(
        EbFrame.encode(
          7,
          ChannelColor(ChannelLayout.rgbcct, <int>[10, 20, 30, 40, 50]),
          99,
        ),
        <int>[
          0xAA,
          7,
          10,
          20,
          30,
          40,
          50,
          99,
          7 ^ 10 ^ 20 ^ 30 ^ 40 ^ 50 ^ 99 ^ 0x50,
        ],
      );
      expect(
        EbFrame.encode(
          5,
          ChannelColor(ChannelLayout.rgb, <int>[10, 20, 30]),
          99,
        ),
        <int>[0xAA, 5, 10, 20, 30, 99, 5 ^ 10 ^ 20 ^ 30 ^ 99 ^ 0x56],
      );
    });

    test('scene JSON carries its layout', () {
      final EbScene s = EbScene.defaults(ChannelLayout.cct)
          .copyWith(color: ChannelColor(ChannelLayout.cct, <int>[3, 250]));
      expect(EbScene.fromJson(s.toJson()), s);
      final Map<String, Object> bad = s.toJson()..['layout'] = 'RGB';
      expect(EbScene.fromJson(bad), isNull);
    });
  });

  group('identity', () {
    const EbVersion v35 = EbVersion('3.5.0', 3, 5, 0);
    EbCaps caps(String body) => parseEbReply('CAPS:$body') as EbCaps;

    test('the INFO model names the layout', () {
      for (final EbFixtureSpec f in EbFixtureCatalog.all) {
        expect(EbIdentity.layoutFromModel(f.modelId), f.layout);
      }
      Matcher fails(EbIncompatibility kind) => throwsA(
        isA<EbIdentityError>().having(
          (EbIdentityError e) => e.kind,
          'kind',
          kind,
        ),
      );
      expect(
        () => EbIdentity.layoutFromModel('ElectroBright_ESP32C3_BLE'),
        fails(EbIncompatibility.legacyFirmware),
      );
      expect(
        () => EbIdentity.layoutFromModel('SomethingElse'),
        fails(EbIncompatibility.notElectroBright),
      );
      expect(
        () => EbIdentity.layoutFromModel('EB-C3-RGBWW-V1'),
        fails(EbIncompatibility.unknownLayout),
      );
    });

    test('CAPS confirms the layout and names the supported modes', () {
      for (final EbFixtureSpec f in EbFixtureCatalog.all) {
        final LightCapabilities c = EbIdentity.capabilities(
          fromModel: f.layout,
          version: v35,
          caps: parseEbReply(f.capsReply) as EbCaps,
          modeSettingsPairs: 13,
        );
        expect(c.layout, f.layout);
        expect(c.modeMask, f.modeMask);
      }
      final LightCapabilities w = EbIdentity.capabilities(
        fromModel: ChannelLayout.w,
        version: v35,
        caps: parseEbReply(EbFixtureCatalog.w.capsReply) as EbCaps,
        modeSettingsPairs: 13,
      );
      expect(w.supportsMode(10), isFalse);
      expect(w.modes, hasLength(12));
    });

    test('CAPS PRESETS= is the slot count; earlier firmware gets 15', () {
      LightCapabilities of(String body, [EbVersion v = v35]) =>
          EbIdentity.capabilities(
            fromModel: ChannelLayout.rgb,
            version: v,
            caps: caps(body),
            modeSettingsPairs: 13,
          );
      const String base = 'PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL';
      // Every current fixture announces 15.
      final EbVersion current =
          parseEbReply('VERSION:${EbDeviceModel.firmwareVersion}') as EbVersion;
      for (final EbFixtureSpec f in EbFixtureCatalog.all) {
        final LightCapabilities c = EbIdentity.capabilities(
          fromModel: f.layout,
          version: current,
          caps: parseEbReply(f.capsReply) as EbCaps,
          modeSettingsPairs: 13,
        );
        expect(c.presetSlots, 15, reason: f.modelId);
      }
      // 3.5.0 has no PRESETS key: the current count.
      expect(of('$base,LAYOUT=RGB').presetSlots, Eb.numPresets);
      expect(Eb.numPresets, 15);
      // Fewer is taken as is; more, zero or garbage is kept in range.
      expect(of('$base,PRESETS=10,LAYOUT=RGB').presetSlots, 10);
      expect(of('$base,PRESETS=25,LAYOUT=RGB').presetSlots, 15);
      expect(of('$base,PRESETS=0,LAYOUT=RGB').presetSlots, 1);
      expect(of('$base,PRESETS=x,LAYOUT=RGB').presetSlots, 15);
    });

    test('CAPS IDENTIFY=1 sets supportsIdentify; absent means false', () {
      LightCapabilities of(String body) => EbIdentity.capabilities(
        fromModel: ChannelLayout.rgb,
        version: v35,
        caps: caps(body),
        modeSettingsPairs: 13,
      );
      const String base = 'PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL';
      expect(of('$base,LAYOUT=RGB').supportsIdentify, isFalse);
      expect(of('$base,IDENTIFY=1,LAYOUT=RGB').supportsIdentify, isTrue);
      expect(of('$base,IDENTIFY=0,LAYOUT=RGB').supportsIdentify, isFalse);
      // Every current fixture announces it.
      for (final EbFixtureSpec f in EbFixtureCatalog.all) {
        expect(
          (parseEbReply(f.capsReply) as EbCaps).identify,
          isTrue,
          reason: f.modelId,
        );
      }
      // Saved with the fixture; older saved records read back as false.
      const LightCapabilities withIdentify = LightCapabilities(
        layout: ChannelLayout.cct,
        supportsIdentify: true,
      );
      expect(LightCapabilities.fromJson(withIdentify.toJson()), withIdentify);
      final Map<String, Object> old = withIdentify.toJson()
        ..remove('supportsIdentify');
      expect(LightCapabilities.fromJson(old)!.supportsIdentify, isFalse);
      expect(
        LightCapabilities.assumed(ChannelLayout.cct).supportsIdentify,
        isFalse,
      );
    });

    test('capabilities saved with 25 slots come back with 15', () {
      final Map<String, Object> saved = const LightCapabilities(
        layout: ChannelLayout.cct,
        presetSlots: 25,
      ).toJson();
      expect(LightCapabilities.fromJson(saved)!.presetSlots, 15);
      expect(LightCapabilities.assumed(ChannelLayout.cct).presetSlots, 15);
    });

    test('RGBW 3.4.0 (no LAYOUT key) is RGBW with every mode', () {
      final LightCapabilities c = EbIdentity.capabilities(
        fromModel: ChannelLayout.rgbw,
        version: const EbVersion('3.4.0', 3, 4, 0),
        caps: caps('PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL'),
        modeSettingsPairs: 13,
      );
      expect(c.layout, ChannelLayout.rgbw);
      expect(c.modes, hasLength(13));
    });

    test('mismatches and bad values are refused', () {
      Matcher fails(EbIncompatibility kind) => throwsA(
        isA<EbIdentityError>().having(
          (EbIdentityError e) => e.kind,
          'kind',
          kind,
        ),
      );
      LightCapabilities run(
        ChannelLayout l,
        String body, {
        int pairs = 13,
        EbVersion v = v35,
      }) => EbIdentity.capabilities(
        fromModel: l,
        version: v,
        caps: caps(body),
        modeSettingsPairs: pairs,
      );
      expect(
        () => run(ChannelLayout.cct, 'PROTOCOL=1,LAYOUT=RGB'),
        fails(EbIncompatibility.layoutMismatch),
      );
      expect(
        () => run(ChannelLayout.cct, 'PROTOCOL=1'),
        fails(EbIncompatibility.layoutMismatch),
      );
      expect(
        () => run(ChannelLayout.rgb, 'PROTOCOL=2,LAYOUT=RGB'),
        fails(EbIncompatibility.legacyFirmware),
      );
      expect(
        () => run(
          ChannelLayout.rgb,
          'PROTOCOL=1,LAYOUT=RGB',
          v: const EbVersion('2.9.0', 2, 9, 0),
        ),
        fails(EbIncompatibility.legacyFirmware),
      );
      expect(
        () => run(ChannelLayout.w, 'PROTOCOL=1,LAYOUT=W,MODES=0'),
        fails(EbIncompatibility.modeCount),
      );
      expect(
        () => run(ChannelLayout.w, 'PROTOCOL=1,LAYOUT=W,MODES=zz'),
        fails(EbIncompatibility.modeCount),
      );
      expect(
        () => run(ChannelLayout.w, 'PROTOCOL=1,LAYOUT=W,MODES=FFFF'),
        fails(EbIncompatibility.modeCount),
      );
      expect(
        () => run(ChannelLayout.rgb, 'PROTOCOL=1,LAYOUT=RGB', pairs: 12),
        fails(EbIncompatibility.modeCount),
      );
    });
  });

  group('catalogue', () {
    test('BLE names hint at the layout', () {
      for (final EbFixtureSpec f in EbFixtureCatalog.all) {
        expect(EbFixtureCatalog.layoutFromBleName(f.bleName), f.layout);
      }
      expect(EbFixtureCatalog.layoutFromBleName('ElectroBright_BLE'), isNull);
      expect(
        EbFixtureCatalog.layoutFromBleName('ElectroBright_C3_XYZ_V1'),
        isNull,
      );
      expect(EbFixtureCatalog.layoutFromBleName(null), isNull);
    });

    test('defaults fit their layouts', () {
      for (final EbFixtureSpec f in EbFixtureCatalog.all) {
        final EbScene s = EbScene.defaults(f.layout);
        expect(s.layout, f.layout);
        expect(s.color, f.color);
      }
    });

    test('capabilities round-trip through JSON', () {
      const LightCapabilities c = LightCapabilities(
        layout: ChannelLayout.w,
        modeMask: 0x1DFF,
      );
      expect(LightCapabilities.fromJson(c.toJson()), c);
      expect(
        LightCapabilities.fromJson(<String, Object>{'layout': 'W'}),
        isNull,
      );
    });
  });
}
