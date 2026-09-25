import 'dart:math';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_command.dart';
import 'package:electrobright/core/protocol/eb/eb_frame.dart';
import 'package:electrobright/core/protocol/eb/eb_reply.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/protocol/eb/line_reassembler.dart';
import 'package:electrobright/core/protocol/eb/reply_grammar.dart';
import 'package:electrobright/core/protocol/eb/text_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reply parser', () {
    test('STATUS: all 23 fields, strict ranges', () {
      final EbReply r = parseEbReply(
        'STATUS:1,2,3,4,77,11,8,3,1,0,0,1,1,42,0,9,8,7,6,5,4,3,2',
      );
      expect(r, isA<EbStatusReply>());
      final EbStatus s = (r as EbStatusReply).status;
      expect(s.color, ChannelColor.rgbw(1, 2, 3, 4));
      expect(s.brightness, 77);
      expect(s.mode, 11);
      expect((s.speed, s.frequency), (8, 3));
      expect(s.fireworkColorMode, 1);
      expect(s.sleeping && s.timerActive, isTrue);
      expect(s.timerRemainingSec, 42);
      expect(s.soundOn, isFalse);
      expect(s.policeA, ChannelColor.rgbw(9, 8, 7, 6));
      expect(s.policeB, ChannelColor.rgbw(5, 4, 3, 2));
    });

    test('STATUS rejects wrong field counts and out-of-range values', () {
      const String ok =
          '255,255,255,0,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,255';
      expect(parseEbReply('STATUS:$ok'), isA<EbStatusReply>());
      expect(
        parseEbReply('STATUS:${ok.substring(0, ok.lastIndexOf(','))}'),
        isA<EbMalformed>(),
      );
      expect(parseEbReply('STATUS:$ok,1'), isA<EbMalformed>());
      expect(
        parseEbReply('STATUS:${ok.replaceFirst('255', '256')}'),
        isA<EbMalformed>(),
      );
      expect(
        parseEbReply('STATUS:${ok.replaceFirst(',1,5,5,', ',14,5,5,')}'),
        isA<EbMalformed>(),
      );
      expect(
        parseEbReply('STATUS:${ok.replaceFirst(',1,5,5,', ',1,0,5,')}'),
        isA<EbMalformed>(),
      );
      expect(
        parseEbReply('STATUS:${ok.replaceFirst('255', '-1')}'),
        isA<EbMalformed>(),
      );
      expect(
        parseEbReply('STATUS:${ok.replaceFirst('255', ' 255')}'),
        isA<EbMalformed>(),
      );
    });

    test('other replies', () {
      expect(parseEbReply('OK'), isA<EbOk>());
      expect(
        (parseEbReply('INFO:EB-C3-RGBW-V1') as EbInfo).model,
        'EB-C3-RGBW-V1',
      );
      final EbVersion v = parseEbReply('VERSION:3.4.0') as EbVersion;
      expect((v.major, v.minor, v.patch), (3, 4, 0));
      final EbCaps caps = parseEbReply(
        'CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL',
      ) as EbCaps;
      expect(caps.protocol, 1);
      expect(caps.fields['GAMMA'], '2.2');
      final EbModeSettings ms = parseEbReply(
        'MODE_SETTINGS:1,2;3,4;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;5,5;10,9',
      ) as EbModeSettings;
      expect(ms.levels.length, 13);
      expect(ms.levels.first, const EbLevels(1, 2));
      expect(ms.levels.last, const EbLevels(10, 9));
      expect((parseEbReply('PRESETS:') as EbPresets).slots, isEmpty);
      expect((parseEbReply('PRESETS:0,3,24,') as EbPresets).slots, <int>{
        0,
        3,
        24,
      });
      // A 3.5.0 light may list slots a 15-slot light does not have.
      expect(
        (parseEbReply('PRESETS:0,3,14,15,24,') as EbPresets).within(15).slots,
        <int>{0, 3, 14},
      );
      expect(parseEbReply('PRESETS:0,3'), isA<EbMalformed>());
      expect(parseEbReply('PRESETS:3,3,'), isA<EbMalformed>());
      final EbCapabilities c = parseEbReply(
        'CAPABILITIES:SPEED,FREQUENCY,COLOR_MODE',
      ) as EbCapabilities;
      expect((c.speed, c.frequency, c.colorMode), (true, true, true));
      final EbCapabilities none =
          parseEbReply('CAPABILITIES:NONE') as EbCapabilities;
      expect((none.speed, none.frequency), (false, false));
      expect(parseEbReply('CAPABILITIES:SPEED,SPEED'), isA<EbMalformed>());
      final EbError e = parseEbReply('ERROR:PRESET_EMPTY:7') as EbError;
      expect((e.code, e.presetId), (EbError.presetEmpty, 7));
      expect(
        (parseEbReply('ERROR:MODE_INVALID') as EbError).code,
        'MODE_INVALID',
      );
      expect(
        (parseEbReply('DIAG:rx=3,gaps=0,up=12') as EbDiag).values['up'],
        12,
      );
      expect(parseEbReply('ok'), isA<EbMalformed>());
      expect(parseEbReply('NOPE:1'), isA<EbMalformed>());
      expect(parseEbReply(''), isA<EbMalformed>());
    });

    test('never throws on random input', () {
      final Random r = Random(7);
      const String alphabet = 'STATUSMODEPRESETCAPSERROR:,;=0123456789 -_.';
      for (int i = 0; i < 200000; i++) {
        final String line = String.fromCharCodes(
          List<int>.generate(
            r.nextInt(90),
            (_) => alphabet.codeUnitAt(r.nextInt(alphabet.length)),
          ),
        );
        parseEbReply(line); // must not throw
      }
    });
  });

  group('line reassembler', () {
    test('lines span notifications and share them', () {
      final LineReassembler a = LineReassembler();
      expect(a.add('STATUS:1,2'.codeUnits), isEmpty);
      expect(a.add(',3\nOK\nIN'.codeUnits), <String>['STATUS:1,2,3', 'OK']);
      expect(a.add('FO:X\n'.codeUnits), <String>['INFO:X']);
    });

    test('drops non-ASCII and overlong lines whole', () {
      final LineReassembler a = LineReassembler(maxLineLength: 8);
      expect(
        a.add(<int>[...'OK'.codeUnits, 0xFF, ...'X\nOK\n'.codeUnits]),
        <String>['OK'],
      );
      expect(a.rejected, 1);
      expect(a.add('123456789\nOK\n'.codeUnits), <String>['OK']);
      expect(a.overflows, 1);
      expect(a.add('\r\n\n'.codeUnits), isEmpty);
    });
  });

  group('writes', () {
    test('binary frame matches the firmware encoder', () {
      expect(EbFrame.encode(0x12, ChannelColor.rgbw(1, 2, 3, 4), 5), <int>[
        0xAA,
        0x12,
        1,
        2,
        3,
        4,
        5,
        0x12 ^ 1 ^ 2 ^ 3 ^ 4 ^ 5 ^ 0x55,
      ]);
      expect(
        EbFrame.encode(256 + 7, ChannelColor.black(ChannelLayout.rgbw), 0)[1],
        7,
      );
    });

    test('commands are chunked to the MTU and never below 20 bytes', () {
      final List<List<int>> small = chunkCommand(
        'POLICE_COLOR_A:255,255,255,255',
        23,
      );
      expect(small.map((List<int> c) => c.length), <int>[20, 11]);
      expect(
        String.fromCharCodes(small.expand((List<int> c) => c)),
        'POLICE_COLOR_A:255,255,255,255\n',
      );
      expect(chunkCommand('PING', 247).single, 'PING\n'.codeUnits);
      expect(chunkCommand('PING', 10).single.length, 5);
      expect(lineResetWrite, <int>[0x15, 0x0A]);
    });

    test('commands validate their arguments', () {
      expect(SetMode(13).wire, 'MODE:13');
      expect(() => SetMode(0), throwsRangeError);
      expect(() => SetModeSpeed(3, 11), throwsRangeError);
      expect(SetModeFrequency(12, 1).wire, 'MODE_FREQUENCY:12,1');
      expect(
        SetPoliceColor(EbPoliceSlot.b, ChannelColor.rgbw(0, 0, 0, 255)).wire,
        'POLICE_COLOR_B:0,0,0,255',
      );
      expect(
        () => SetPoliceColor(EbPoliceSlot.a, ChannelColor.rgbw(0, 0, 0, 256)),
        throwsArgumentError,
      );
      expect(SetColorMode(EbColorModeKind.club, 1).wire, 'CLUB_COLOR_MODE:1');
      expect(() => SetTimer(86401), throwsRangeError);
      expect(() => PresetLoad(25), throwsRangeError);
      expect(const SetPower(on: false).wire, 'SLEEP');
      expect(const SetSound(on: true).wire, 'SOUND_ON');
      for (final EbCommand c in <EbCommand>[
        SetMode(1),
        SetPoliceColor(EbPoliceSlot.a, ChannelColor.rgbw(255, 255, 255, 255)),
        SetTimer(86400),
        const FactoryReset(),
      ]) {
        expect(c.wire.length, lessThanOrEqualTo(96), reason: '$c');
      }
    });
  });

  group('reply grammar', () {
    test('OK commands', () {
      expect(matchReply(EbExpect.ok, const EbOk()), ReplyMatch.success);
      expect(
        matchReply(EbExpect.ok, const EbError('MODE_INVALID')),
        ReplyMatch.failure,
      );
      expect(
        matchReply(EbExpect.ok, const EbError(EbError.storage)),
        ReplyMatch.none,
      );
      expect(
        matchReply(EbExpect.ok, const EbError(EbError.unknownCommand)),
        ReplyMatch.failure,
      );
    });

    test('storage roles', () {
      expect(
        matchReply(EbExpect.okStorageNote, const EbError(EbError.storage)),
        ReplyMatch.note,
      );
      expect(
        matchReply(EbExpect.okStorageNote, const EbOk()),
        ReplyMatch.success,
      );
      expect(
        matchReply(
          EbExpect.okStorageProvisional,
          const EbError(EbError.storage),
        ),
        ReplyMatch.provisional,
      );
      expect(
        matchReply(
          EbExpect.okStorageProvisional,
          const EbError(EbError.presetIdInvalid),
        ),
        ReplyMatch.failure,
      );
    });

    test('PRESET_LOAD tells its STATUS from the timer push', () {
      EbStatusReply status({required bool sleeping}) => EbStatusReply(
        EbStatus(
          color: ChannelColor.black(ChannelLayout.rgbw),
          brightness: 0,
          mode: 1,
          speed: 5,
          frequency: 5,
          fireworkColorMode: 0,
          clubColorMode: 0,
          policeColorMode: 1,
          sleeping: sleeping,
          timerActive: false,
          timerRemainingSec: 0,
          soundOn: true,
          policeA: ChannelColor.black(ChannelLayout.rgbw),
          policeB: ChannelColor.black(ChannelLayout.rgbw),
        ),
      );
      expect(
        matchReply(EbExpect.presetLoad, status(sleeping: false)),
        ReplyMatch.success,
      );
      expect(
        matchReply(EbExpect.presetLoad, status(sleeping: true)),
        ReplyMatch.none,
      );
      expect(
        matchReply(
          EbExpect.presetLoad,
          const EbError(EbError.presetEmpty, presetId: 3),
        ),
        ReplyMatch.failure,
      );
    });

    test('typed queries only accept their reply', () {
      expect(matchReply(EbExpect.status, const EbOk()), ReplyMatch.none);
      expect(matchReply(EbExpect.info, const EbInfo('x')), ReplyMatch.success);
      expect(
        matchReply(EbExpect.capabilities, const EbError(EbError.modeInvalid)),
        ReplyMatch.failure,
      );
    });
  });

  group('scene', () {
    test('JSON round trip and strict decoding', () {
      final EbScene s = EbScene.defaults(ChannelLayout.rgbw)
          .withSpeed(6, 9)
          .withColorMode(EbColorModeKind.police, 0)
          .withPolice(EbPoliceSlot.b, ChannelColor.rgbw(1, 2, 3, 4));
      expect(EbScene.fromJson(s.toJson()), s);
      final Map<String, Object> bad = s.toJson()..['mode'] = 14;
      expect(EbScene.fromJson(bad), isNull);
      expect(EbScene.fromJson('nope'), isNull);
    });
  });
}
