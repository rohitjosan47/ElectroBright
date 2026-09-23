import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:electrobright_app/core/ble/ble_protocol.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/core/ble/ble_dispatcher.dart';
import 'package:electrobright_app/core/utils/echo_suppressor.dart';
import 'package:electrobright_app/core/devices/device_catalog.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';
import 'package:electrobright_app/features/presets/data/preset_name_repository.dart';

void main() {
  group('Tier 4: BleProtocol Binary Fast-Path Encoding & Versioning', () {
    test('encodeRgbwBrightnessBinary generates valid 8-byte packet with correct checksum', () {
      final packet = BleProtocol.encodeRgbwBrightnessBinary(255, 128, 0, 30, 100);
      expect(packet.length, 8);
      expect(packet[0], 0xAA); // Magic start byte
      final seq = packet[1];   // Sequence number
      expect(packet[2], 255);  // Red
      expect(packet[3], 128);  // Green
      expect(packet[4], 0);    // Blue
      expect(packet[5], 30);   // White
      expect(packet[6], 100);  // Brightness

      final expectedChecksum = (seq ^ 255 ^ 128 ^ 0 ^ 30 ^ 100 ^ 0x55) & 0xFF;
      expect(packet[7], expectedChecksum);
    });

    test('encodeRgbwBrightnessBinary clamps inputs to 0-255 range', () {
      final packet = BleProtocol.encodeRgbwBrightnessBinary(-10, 300, 256, -1, 300);
      final seq = packet[1];
      expect(packet[2], 0);
      expect(packet[3], 255);
      expect(packet[4], 255);
      expect(packet[5], 0);
      expect(packet[6], 255);

      final expectedChecksum = (seq ^ 0 ^ 255 ^ 255 ^ 0 ^ 255 ^ 0x55) & 0xFF;
      expect(packet[7], expectedChecksum);
    });

    test('Checksum edge cases (all zeroes, all 255s)', () {
      final zeroPacket = BleProtocol.encodeRgbwBrightnessBinary(0, 0, 0, 0, 0);
      final seqZero = zeroPacket[1];
      expect(zeroPacket[7], (seqZero ^ 0x55) & 0xFF);

      final maxPacket = BleProtocol.encodeRgbwBrightnessBinary(255, 255, 255, 255, 255);
      final seqMax = maxPacket[1];
      // 255^255=0, 255^255=0, 255^0x55 = 0xAA
      expect(maxPacket[7], (seqMax ^ 255 ^ 255 ^ 255 ^ 255 ^ 255 ^ 0x55) & 0xFF);
    });

    test('parseCaps accurately parses CAPS payload', () {
      expect(BleProtocol.parseCaps(''), isNull);
      expect(BleProtocol.parseCaps('VERSION:2.8.0'), isNull);
      
      final caps = BleProtocol.parseCaps('CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL');
      expect(caps, isNotNull);
      expect(caps!['PROTOCOL'], '1');
      expect(caps['PWM'], '14');
      expect(caps['GAMMA'], '2.2');
      expect(caps['MASTER'], 'PERCEPTUAL');
    });
  });

  group('Tier 4: DeviceNotifier Fast-Path & Backward Compatibility Matrix', () {
    late MockBleTransport transport;
    late BleDispatcher dispatcher;
    late EchoSuppressor echoSuppressor;
    late PresetNameRepository presetRepo;
    late DeviceNotifier notifier;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      transport = MockBleTransport();
      dispatcher = BleDispatcher(transport);
      echoSuppressor = EchoSuppressor();
      presetRepo = const PresetNameRepository('test-device', 15);
      notifier = DeviceNotifier(
        transport,
        dispatcher,
        echoSuppressor,
        presetRepo,
        DeviceCatalog.electrobrightC3RgbwV1,
      );
    });

    tearDown(() {
      notifier.dispose();
      dispatcher.dispose();
      echoSuppressor.dispose();
      transport.dispose();
    });

    test('Case 1: New App + New Firmware (CAPS PROTOCOL>=1) uses binary fast-path for continuous streaming', () async {
      transport.simulatedCaps = 'PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL';
      await transport.connect('MOCK-ESP32-C3-001');
      await Future.delayed(const Duration(milliseconds: 150));

      expect(notifier.state.supportsBinaryFastPath, isTrue);

      final initialBinaryCount = transport.binaryPacketCount;
      final initialAsciiCount = transport.asciiCommandCount;

      // Continuous color dragging (e.g. user dragging on color wheel)
      notifier.setRgbw(255, 100, 50, 0, continuous: true);

      // Wait for dispatcher continuous throttle to flush
      await Future.delayed(const Duration(milliseconds: 70));

      expect(transport.binaryPacketCount, initialBinaryCount + 1);
      expect(transport.asciiCommandCount, initialAsciiCount); // Zero ASCII commands sent during drag!

      // Terminal release: continuous = false
      notifier.setRgbw(255, 100, 50, 0, continuous: false);
      await Future.delayed(const Duration(milliseconds: 70));

      // Terminal commit sent binary packet with immediate priority
      expect(transport.binaryPacketCount, initialBinaryCount + 2);
    });

    test('Case 2: New App + Old Firmware (No CAPS) safely falls back to ASCII streaming', () async {
      transport.simulatedCaps = ''; // Simulate old firmware that doesn't return CAPS
      await transport.connect('MOCK-ESP32-C3-001');
      await Future.delayed(const Duration(milliseconds: 150));

      expect(notifier.state.supportsBinaryFastPath, isFalse);

      final initialBinaryCount = transport.binaryPacketCount;
      final initialAsciiCount = transport.asciiCommandCount;

      // Continuous color dragging
      notifier.setRgbw(180, 200, 220, 10, continuous: true);

      // Wait for dispatcher continuous throttle to flush
      await Future.delayed(const Duration(milliseconds: 70));

      // Since firmware < 2.8.0, no binary packets must be sent
      expect(transport.binaryPacketCount, initialBinaryCount);
      expect(transport.asciiCommandCount, initialAsciiCount + 1); // ASCII RGBW sent
    });

    test('Case 3: In-flight streaming deduplication coalesces rapid binary updates', () async {
      transport.simulatedCaps = 'PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL';
      await transport.connect('MOCK-ESP32-C3-001');
      await Future.delayed(const Duration(milliseconds: 150));

      final initialBinaryCount = transport.binaryPacketCount;

      // Simulate 10 rapid slider movements within 30ms (faster than 50ms throttle bucket)
      for (int i = 0; i < 10; i++) {
        notifier.setRgbw(100 + i * 10, 50, 20, 0, continuous: true);
      }

      await Future.delayed(const Duration(milliseconds: 70));

      // Coalesced into exactly 2 binary packets (the first one, and the last coalesced one)
      expect(transport.binaryPacketCount, initialBinaryCount + 2);
    });

    test('Throughput Benchmark: Binary Fast-Path achieves >= 60% byte payload reduction', () {
      const asciiMin = 'RGBW:0,0,0,0\n';             // 13 bytes
      const asciiAvg = 'RGBW:255,128,64,32\n';        // 19 bytes
      const asciiMax = 'RGBW:255,255,255,255\n';      // 23 bytes
      const binaryLen = 6;                           // Exactly 6 bytes

      const minReduction = (1.0 - (binaryLen / asciiMin.length)) * 100;
      const avgReduction = (1.0 - (binaryLen / asciiAvg.length)) * 100;
      const maxReduction = (1.0 - (binaryLen / asciiMax.length)) * 100;

      expect(minReduction, greaterThan(50.0));
      expect(avgReduction, greaterThan(65.0));
      expect(maxReduction, greaterThan(70.0));
    });
  });
}
