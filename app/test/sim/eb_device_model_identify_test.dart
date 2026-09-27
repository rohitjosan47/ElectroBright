import 'dart:convert';
import 'dart:typed_data';

import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// IDENTIFY in the firmware twin: replies OK, flashes the demo output twice
/// (150 ms full, 150 ms dark), then restores it; changes no state.
void main() {
  EbDeviceModel connected() {
    final EbDeviceModel m = EbDeviceModel()
      ..connect()
      ..setMtu(247)
      ..setSubscribed(subscribed: true)
      ..pass();
    m
      ..takeNotifications()
      ..takeSounds();
    return m;
  }

  String send(EbDeviceModel m, String line) {
    m
      ..write(utf8.encode('$line\n'))
      ..pass();
    return m.takeNotifications().map((Uint8List n) => utf8.decode(n)).join();
  }

  test('the simulator reports its firmware version, IDENTIFY in CAPS', () {
    final EbDeviceModel m = connected();
    // test/cross_repo checks the constant against the firmware's Config.h.
    expect(send(m, 'VERSION'), 'VERSION:${EbDeviceModel.firmwareVersion}\n');
    expect(send(m, 'CAPS'), contains('IDENTIFY=1'));
  });

  test('IDENTIFY flashes twice, then restores the output', () {
    final EbDeviceModel m = connected();
    final Map<String, Object> before = m.state();
    expect(m.identifyFlash, isNull);
    expect(send(m, 'IDENTIFY'), 'OK\n');
    expect(m.takeSounds(), <String>['Identify']);
    final List<bool?> seen = <bool?>[];
    for (int t = 0; t < 700; t += 10) {
      seen.add(m.identifyFlash);
      m.advance(10);
    }
    // 2 flashes: lit, dark, lit, dark, then the normal output.
    final List<bool?> runs = <bool?>[];
    for (final bool? s in seen) {
      if (runs.isEmpty || runs.last != s) runs.add(s);
    }
    expect(runs, <bool?>[true, false, true, false, null]);
    expect(seen.where((bool? s) => s == true).length, 30); // 2 x 150 ms
    final Map<String, Object> after = m.state();
    expect(after['scene'], before['scene']);
    expect(after['sleeping'], before['sleeping']);
  });

  test('IDENTIFY works asleep without waking; state changes cancel it', () {
    final EbDeviceModel m = connected();
    send(m, 'SLEEP');
    m.takeSounds();
    expect(send(m, 'IDENTIFY'), 'OK\n');
    expect(m.identifyFlash, isTrue);
    expect(m.sleeping, isTrue);
    expect(m.takeSounds(), <String>['Identify']);
    m.advance(200);
    expect(send(m, 'IDENTIFY'), 'OK\n'); // restart
    expect(m.identifyFlash, isTrue);
    send(m, 'STATUS'); // a query keeps it running
    expect(m.identifyFlash, isTrue);
    send(m, 'BRIGHTNESS:40'); // a state change cancels it
    expect(m.identifyFlash, isNull);
    expect(send(m, 'IDENTIFY:1'), 'ERROR:FORMAT\n');
  });
}
