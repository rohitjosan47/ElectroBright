import 'dart:convert';
import 'dart:typed_data';

import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The firmware twin as the universal firmware 3.7.0: the stored fixture
/// type, SET_TYPE, PROBE, CAPS TYPES= and setup-needed mode (the same rules
/// as firmware/test/test_universal.cpp).
void main() {
  void link(EbDeviceModel m) {
    m
      ..connect()
      ..setMtu(247)
      ..setSubscribed(subscribed: true)
      ..pass();
    m
      ..takeNotifications()
      ..takeSounds();
  }

  EbDeviceModel connected({EbFixtureSpec? fixture = EbFixtureCatalog.rgbw}) {
    final EbDeviceModel m = EbDeviceModel(fixture: fixture);
    link(m);
    return m;
  }

  String send(EbDeviceModel m, String line) {
    m
      ..write(utf8.encode('$line\n'))
      ..pass();
    return m.takeNotifications().map((Uint8List n) => utf8.decode(n)).join();
  }

  const String types = 'TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1';

  test('CAPS lists the types and PROBE before LAYOUT', () {
    final EbDeviceModel m = connected();
    expect(send(m, 'VERSION'), 'VERSION:${EbDeviceModel.firmwareVersion}\n');
    expect(
      send(m, 'CAPS'),
      'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,'
      'IDENTIFY=1,$types,LAYOUT=RGBW\n',
    );
  });

  test('SET_TYPE stores the type, clears presets and scene, restarts', () {
    final EbDeviceModel m = connected();
    expect(send(m, 'PRESET_SAVE:2'), 'OK\n');
    expect(send(m, 'MODE:6'), 'OK\n');
    m.advance(16000);
    expect(send(m, 'SET_TYPE:CCT'), 'OK\n'); // delivered before the restart
    expect(m.restarts, 1);
    expect(m.connected, isFalse);
    expect(m.fixture, same(EbFixtureCatalog.cct));
    expect(m.presetSlots, isEmpty);
    expect(m.scene, EbScene.defaults(EbFixtureCatalog.cct.layout));

    link(m);
    expect(send(m, 'INFO'), 'INFO:EB-C3-CCT-V1\n');
    expect(send(m, 'CAPS'), endsWith('LAYOUT=CCT\n'));
    // The type survives power cycles and FACTORY_RESET.
    expect(send(m, 'FACTORY_RESET'), 'OK\n');
    m.reboot();
    expect(m.fixture, same(EbFixtureCatalog.cct));
  });

  test('SET_TYPE: same type is a no-op; invalid names are rejected', () {
    final EbDeviceModel m = connected(fixture: EbFixtureCatalog.rgb);
    expect(send(m, 'PRESET_SAVE:1'), 'OK\n');
    expect(send(m, 'SET_TYPE:rgb'), 'OK\n');
    expect(m.restarts, 0);
    expect(m.presetSlots, <int>{1});
    for (final String bad in <String>[
      'SET_TYPE',
      'SET_TYPE:NONE',
      'SET_TYPE:RGBWW',
      'SET_TYPE:1',
    ]) {
      expect(send(m, bad), 'ERROR:TYPE_INVALID\n', reason: bad);
    }
    expect(m.fixture, same(EbFixtureCatalog.rgb));
  });

  test('PROBE: one output, expires after 3 s, any other command ends it', () {
    final EbDeviceModel m = connected();
    int probe() =>
        ((m.state()['render']! as Map<String, Object>)['probe']!) as int;
    final Map<String, Object> scene = m.state()['scene']! as Map<String, Object>;
    expect(send(m, 'PROBE:4:1'), 'OK\n');
    expect(probe(), 5);
    expect(send(m, 'PROBE:1:1'), 'OK\n');
    expect(probe(), 2); // switched, not added
    m.advance(2900);
    expect(probe(), 2);
    m.advance(200);
    expect(probe(), 0);
    expect(send(m, 'PROBE:0:1'), 'OK\n');
    expect(send(m, 'STATUS'), startsWith('STATUS:'));
    expect(probe(), 0);
    expect(m.state()['scene'], scene); // nothing changed or stored
    for (final String bad in <String>['PROBE:5:1', 'PROBE:1:2', 'PROBE:1,1']) {
      expect(send(m, bad), 'ERROR:PROBE_INVALID\n', reason: bad);
    }
  });

  test('setup-needed mode: outputs off, only the setup commands', () {
    final EbDeviceModel m = connected(fixture: null);
    expect(m.setupNeeded, isTrue);
    expect(
      send(m, 'CAPS'),
      'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,'
      'IDENTIFY=1,$types,LAYOUT=NONE\n',
    );
    expect(send(m, 'VERSION'), 'VERSION:${EbDeviceModel.firmwareVersion}\n');
    expect(send(m, 'DIAG'), startsWith('DIAG:'));
    expect(send(m, 'PROBE:3:1'), 'OK\n');
    expect(send(m, 'IDENTIFY'), 'OK\n');
    expect(m.takeSounds(), <String>['Identify']);
    expect(m.identifyFlash, isNull); // the buzzer only
    for (final String cmd in <String>[
      'INFO',
      'STATUS',
      'PING',
      'COLOR:1,2,3,4',
      'MODE:1',
      'PRESET_LIST',
      'FACTORY_RESET',
    ]) {
      expect(send(m, cmd), 'ERROR:SETUP_NEEDED\n', reason: cmd);
    }
    expect(send(m, 'RGBW:1,2,3,4'), 'ERROR:UNKNOWN_CMD\n');

    expect(send(m, 'SET_TYPE:W'), 'OK\n');
    expect(m.setupNeeded, isFalse);
    expect(m.fixture, same(EbFixtureCatalog.w));
  });
}
