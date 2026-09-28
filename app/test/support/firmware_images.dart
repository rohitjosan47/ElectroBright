import 'dart:math';
import 'dart:typed_data';

import 'package:electrobright/core/firmware/firmware_bundle.dart';
import 'package:electrobright/sim/ota_twin.dart';

/// A fake ElectroBright universal image of [size] bytes: the ESP image magic,
/// the identity block at 0x120 (where the linker puts it; [product] replaces
/// the product name, [identity] false leaves the block out) and seeded
/// pseudo-random bytes.
FirmwareImage testImage({
  String version = '3.9.0',
  int size = 40000,
  int seed = 1,
  String? product,
  bool identity = true,
  int rollbackTest = 0,
}) {
  final Random r = Random(seed);
  final Uint8List img = Uint8List(size);
  for (int i = 0; i < size; i++) {
    img[i] = r.nextInt(256);
  }
  img[0] = 0xE9;
  if (identity) {
    img.setAll(
      0x120,
      ImageIdentityTwin.build(
        version: version,
        productName: product ?? ImageIdentityTwin.product,
        rollbackTest: rollbackTest,
      ),
    );
  }
  return FirmwareImage(bytes: img, version: FirmwareVersion.tryParse(version)!);
}
