import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:electrobright/core/firmware/firmware_bundle.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/ota_twin.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firmware_sources.dart';

/// The firmware bundled for wireless updates (tool/bundle_firmware.sh) must
/// be the image its manifest describes, of the firmware's own version, and
/// one the lights accept (an ElectroBright universal identity block).
void main() {
  final File manifestFile = File(FirmwareBundle.manifestPath);
  final Object? json = jsonDecode(manifestFile.readAsStringSync());
  final FirmwareManifest? manifest = FirmwareManifest.fromJson(json);

  test('the manifest is complete', () {
    expect(manifest, isNotNull, reason: '$json');
    final Map<String, Object?> fields = json! as Map<String, Object?>;
    expect(fields['product'], 'ElectroBright');
    expect(fields['kind'], 'universal');
  });

  test('the manifest matches the bundled image', () {
    final File image = File('${FirmwareBundle.directory}/${manifest!.file}');
    expect(image.existsSync(), isTrue, reason: image.path);
    final Uint8List bytes = image.readAsBytesSync();
    expect(bytes.length, manifest.size);
    expect(
      FirmwareBundle.hex(
        FirmwareImage(bytes: bytes, version: manifest.version).sha256,
      ),
      manifest.sha256,
    );
    // Only the image and its manifest are bundled.
    expect(
      Directory(FirmwareBundle.directory)
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .where((String n) => !n.startsWith('.'))
          .toSet(),
      <String>{'manifest.json', manifest.file},
    );
  });

  test('the image is the firmware version the app knows', () {
    final String version = configConstants()['kFirmwareVersion']!;
    expect('${manifest!.version}', version);
    expect('${manifest.version}', EbDeviceModel.firmwareVersion);
    expect(manifest.file, 'ElectroBright_Update-$version.bin');
    // The identity block the lights check at END.
    final Uint8List bytes = File('${FirmwareBundle.directory}/${manifest.file}')
        .readAsBytesSync();
    expect(bytes.first, 0xE9, reason: 'ESP32 app image magic');
    final int? at = ImageIdentityTwin.find(bytes);
    expect(at, isNotNull);
    expect(ImageIdentityTwin.universalVersion(bytes, at!), <int>[
      manifest.version.major,
      manifest.version.minor,
      manifest.version.patch,
    ]);
    // It fits a light's spare app slot.
    expect(bytes.length, lessThanOrEqualTo(SimOtaFlash().capacity));
  });

  test('the app reads the bundle and checks the image', () async {
    final FirmwareBundle? bundle = await FirmwareBundle.load(
      text: (String p) => File(p).readAsString(),
      bytes: (String p) async =>
          ByteData.sublistView(await File(p).readAsBytes()),
    );
    expect(bundle, isNotNull);
    expect(bundle!.version, manifest!.version);
    final FirmwareImage image = await bundle.image();
    expect(image.size, manifest.size);

    // A manifest that does not match its image is refused.
    final FirmwareBundle wrong = FirmwareBundle(
      FirmwareManifest(
        version: manifest.version,
        size: manifest.size,
        sha256: '0' * 64,
        file: manifest.file,
      ),
      () async => ByteData.sublistView(image.bytes),
    );
    await expectLater(wrong.image(), throwsStateError);
  });

  test('malformed manifests are rejected', () {
    final Map<String, Object?> good = Map<String, Object?>.of(
      json! as Map<String, Object?>,
    );
    expect(FirmwareManifest.fromJson(good), isNotNull);
    for (final MapEntry<String, Object?> bad in <MapEntry<String, Object?>>[
      const MapEntry<String, Object?>('version', '3.8'),
      const MapEntry<String, Object?>('size', 0),
      const MapEntry<String, Object?>('sha256', 'xyz'),
      const MapEntry<String, Object?>('product', 'Other'),
      const MapEntry<String, Object?>('kind', 'rgbw'),
      const MapEntry<String, Object?>('file', '../x.bin'),
    ]) {
      expect(
        FirmwareManifest.fromJson(<String, Object?>{
          ...good,
          bad.key: bad.value,
        }),
        isNull,
        reason: bad.key,
      );
    }
  });
}
