import 'package:electrobright/core/protocol/eb/eb_ota.dart';
import 'package:electrobright/sim/ota_twin.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firmware_sources.dart';

/// The app's wireless-update contract (EbOta) and the firmware twin's update
/// side (ota_twin.dart) must equal the firmware: ota/OtaProtocol.h,
/// ota/ImageIdentity.h, ota/SelfCheck.h, ota/OtaReplies.h and Config.h.
void main() {
  final String protocol = readFirmware('ota/OtaProtocol.h');

  String str(String src, String name) =>
      RegExp('constexpr const char\\* $name = "([^"]*)";')
          .firstMatch(src)!
          .group(1)!;
  int num(String src, String name) {
    final String raw = RegExp('constexpr [\\w:]+ $name = ([^;]+);')
        .firstMatch(src)!
        .group(1)!
        .trim()
        .replaceAll(RegExp(r'[uU]$'), '');
    return raw.startsWith('0x')
        ? int.parse(raw.substring(2), radix: 16)
        : int.parse(raw);
  }

  test('GATT service and characteristics', () {
    expect(str(protocol, 'kServiceUuid').toLowerCase(), EbOta.serviceUuid);
    expect(str(protocol, 'kControlUuid').toLowerCase(), EbOta.controlUuid);
    expect(str(protocol, 'kDataUuid').toLowerCase(), EbOta.dataUuid);
  });

  test('opcodes, lengths, window and timeout', () {
    final Map<String, int> app = <String, int>{
      'kBegin': EbOta.begin,
      'kEnd': EbOta.end,
      'kAbort': EbOta.abort,
      'kStatus': EbOta.status,
      'kBeginLength': EbOta.beginLength,
      'kFlagReinstall': EbOta.flagReinstall,
      'kBeginOk': EbOta.beginOk,
      'kAck': EbOta.ack,
      'kEndOk': EbOta.endOk,
      'kAborted': EbOta.aborted,
      'kState': EbOta.state,
      'kError': EbOta.error,
      'kStateIdle': EbOta.stateIdle,
      'kStateReceiving': EbOta.stateReceiving,
      'kStateRestarting': EbOta.stateRestarting,
      'kDataHeader': EbOta.dataHeader,
      'kWindow': EbOta.window,
      'kTimeoutMs': EbOta.timeoutMs,
    };
    for (final MapEntry<String, int> e in app.entries) {
      expect(num(protocol, e.key), e.value, reason: e.key);
    }
  });

  test('error codes', () {
    final String body = RegExp(
      r'enum class Error : uint8_t \{(.*?)\};',
      dotAll: true,
    ).firstMatch(protocol)!.group(1)!;
    final Map<String, int> fw = <String, int>{
      for (final RegExpMatch m in RegExp(r'(\w+) = (\d+),').allMatches(body))
        m.group(1)!.toLowerCase(): int.parse(m.group(2)!),
    };
    expect(fw, <String, int>{
      for (final EbOtaError e in EbOtaError.values)
        e.name.toLowerCase(): e.code,
    });
  });

  test('identity block, self-check, reply queue and buffers', () {
    final String id = readFirmware('ota/ImageIdentity.h');
    expect(
      RegExp(r'kMagic\[8\] = \{([^}]*)\}')
          .firstMatch(id)!
          .group(1)!
          .replaceAll(RegExp(r"[' ]"), ''),
      String.fromCharCodes(ImageIdentityTwin.magic).split('').join(','),
    );
    expect(str(id, 'kProduct'), ImageIdentityTwin.product);
    expect(str(id, 'kKind'), ImageIdentityTwin.kind);
    expect(num(id, 'kSearchBytes'), ImageIdentityTwin.searchBytes);
    expect(id, contains('sizeof(ImageIdentity) == ${ImageIdentityTwin.size}'));
    // Field layout: magic[8] product[16] kind[12] version[16] reserved[12].
    expect(id, contains('char magic[8];'));
    expect(id, contains('char product[16];'));
    expect(id, contains('char kind[12];'));
    expect(id, contains('char version[16];'));

    final String check = readFirmware('ota/SelfCheck.h');
    expect(num(check, 'kDeadlineMs'), SelfCheckTwin.deadlineMs);
    expect(num(check, 'kMinRenderFrames'), SelfCheckTwin.minRenderFrames);

    final String replies = readFirmware('ota/OtaReplies.h');
    expect(num(replies, 'kCapacity'), OtaRepliesTwin.capacity);
    expect(num(replies, 'kMaxLen'), OtaRepliesTwin.maxLen);

    final Map<String, String> c = configConstants();
    final String twin = readFirmware('sim/eb_device_model.dart', root: 'lib');
    expect(
      twin,
      contains('_otaDataBufferBytes = ${configInt(c, 'kOtaDataBufferBytes')};'),
    );
    expect(twin, contains('_otaMaxWrite = ${configInt(c, 'kOtaMaxWrite')};'));
  });
}
