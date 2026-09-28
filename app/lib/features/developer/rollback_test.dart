import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/firmware/firmware_bundle.dart';
import 'rollback_test_images.g.dart';

/// The two rollback test images (firmware 3.8.1,
/// `build_update_image.sh --rollback-test`): installed wirelessly, each must
/// fail and return to the previous firmware on its own.
enum RollbackTest {
  /// Fails its first-boot self-check (at its 15 s deadline).
  failsCheck,

  /// Freezes its control task before the check; the task watchdog restarts it.
  freezes,
}

/// Whether this build offers the rollback test (debug builds only).
const bool rollbackTestsAvailable = kDebugMode;

/// The rollback test image [test], or null outside debug builds. Only this
/// function reaches the generated data, behind a constant [kDebugMode]
/// check, so profile and release builds tree-shake the images away.
FirmwareBundle? rollbackTestImage(RollbackTest test) {
  if (!kDebugMode) return null;
  final (String manifest, String image) = switch (test) {
    RollbackTest.failsCheck => (
      rollbackTestFailManifest,
      rollbackTestFailImage,
    ),
    RollbackTest.freezes => (
      rollbackTestFreezeManifest,
      rollbackTestFreezeImage,
    ),
  };
  final FirmwareManifest m = FirmwareManifest.fromJson(jsonDecode(manifest))!;
  return FirmwareBundle(
    m,
    () async => ByteData.sublistView(
      Uint8List.fromList(zlib.decode(base64Decode(image))),
    ),
  );
}
