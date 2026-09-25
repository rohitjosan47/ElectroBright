import 'package:electrobright/core/protocol/eb/eb_command.dart';
import 'package:electrobright/core/protocol/eb/eb_constants.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firmware_sources.dart';

/// Protocol constants, identity and the command table must equal the firmware.
void main() {
  final Map<String, String> c = configConstants();

  test('limits and identity match Config.h', () {
    expect(configInt(c, 'kNumModes'), Eb.numModes);
    expect(configInt(c, 'kNumPresets'), Eb.numPresets);
    expect(configInt(c, 'kSleepFadeMs'), Eb.sleepFadeMs);
    expect(configInt(c, 'kMinLevel'), Eb.minLevel);
    expect(configInt(c, 'kMaxLevel'), Eb.maxLevel);
    expect(configInt(c, 'kTimerMaxSeconds'), Eb.timerMaxSeconds);
    expect(configInt(c, 'kMaxLineLength'), Eb.maxLineLength);
    expect(c['kServiceUuid']!.toLowerCase(), Eb.serviceUuid);
    expect(c['kRxCharUuid']!.toLowerCase(), Eb.rxUuid);
    expect(c['kTxCharUuid']!.toLowerCase(), Eb.txUuid);
    expect(c['kDeviceName'], startsWith(Eb.namePrefix));
    expect(Eb.modelPattern.hasMatch(c['kModelId']!), isTrue);
    expect(c['kCapsReply'], contains('PROTOCOL=${Eb.protocolVersion}'));
    expect(
      int.parse(c['kFirmwareVersion']!.split('.').first),
      greaterThanOrEqualTo(Eb.minFirmwareMajor),
    );
  });

  test('the Dart firmware twin reports the firmware identity', () {
    expect(EbDeviceModel.firmwareVersion, c['kFirmwareVersion']);
    expect(EbDeviceModel().modelId, c['kModelId']);
    expect(EbDeviceModel().capsReply, c['kCapsReply']);
  });

  test('typed commands accept exactly the firmware parser ranges', () {
    // {"NAME", CmdId::X, argc, firstMin, firstMax, restMin, restMax, "ERROR"}
    final RegExp spec = RegExp(
      r'\{"(\w+)",\s*CmdId::\w+,\s*(\d),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*"(\w+)"\}',
    );
    final Map<String, int> symbols = <String, int>{
      'kModes': configInt(c, 'kNumModes'),
      'kLvlMin': configInt(c, 'kMinLevel'),
      'kLvlMax': configInt(c, 'kMaxLevel'),
      'kPresetMax': configInt(c, 'kNumPresets') - 1,
      'kTimerMax': configInt(c, 'kTimerMaxSeconds'),
    };
    int value(String s) => int.tryParse(s) ?? symbols[s]!;
    final Map<String, (int, int, int, int)> ranges =
        <String, (int, int, int, int)>{
          for (final RegExpMatch m in spec.allMatches(
            readFirmware('protocol/CommandParser.cpp'),
          ))
            m.group(1)!: (
              value(m.group(3)!),
              value(m.group(4)!),
              value(m.group(5)!),
              value(m.group(6)!),
            ),
        };
    expect(ranges.length, 31, reason: 'every parser row found');

    void accepts(
      String name,
      EbCommand Function(int v) make, {
      bool rest = false,
    }) {
      final (int fMin, int fMax, int rMin, int rMax) = ranges[name]!;
      final int lo = rest ? rMin : fMin;
      final int hi = rest ? rMax : fMax;
      expect(make(lo).wire, isNotEmpty, reason: '$name accepts $lo');
      expect(make(hi).wire, isNotEmpty, reason: '$name accepts $hi');
      expect(
        () => make(lo - 1),
        throwsA(anything),
        reason: '$name rejects ${lo - 1}',
      );
      expect(
        () => make(hi + 1),
        throwsA(anything),
        reason: '$name rejects ${hi + 1}',
      );
    }

    accepts('MODE', SetMode.new);
    accepts('MODE_SPEED', (int m) => SetModeSpeed(m, 5));
    accepts('MODE_SPEED', (int v) => SetModeSpeed(1, v), rest: true);
    accepts('MODE_FREQUENCY', (int m) => SetModeFrequency(m, 5));
    accepts('MODE_FREQUENCY', (int v) => SetModeFrequency(1, v), rest: true);
    accepts('MODE_CAPABILITIES', ModeCapabilitiesQuery.new);
    accepts('PRESET_SAVE', PresetSave.new);
    accepts('PRESET_LOAD', PresetLoad.new);
    accepts('PRESET_DELETE', PresetDelete.new);
    accepts('TIMER', SetTimer.new);
  });
}
