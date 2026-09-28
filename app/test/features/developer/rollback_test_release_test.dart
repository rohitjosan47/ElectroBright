import 'dart:io';

import 'package:electrobright/features/developer/rollback_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Release (and profile) builds must contain neither the rollback test images
/// nor the option to install them. The images are Dart data reached only
/// through rollbackTestImage(), behind a constant kDebugMode check that the
/// AOT compiler folds, so the data and the UI are tree-shaken. These checks
/// keep it that way; tool/check.sh --builds also scans the release binary.
void main() {
  const String generated = 'lib/features/developer/rollback_test_images.g.dart';
  const String gate = 'lib/features/developer/rollback_test.dart';

  test('the images are not assets', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.toLowerCase(), isNot(contains('rollback')));
    for (final FileSystemEntity e in Directory(
      'assets',
    ).listSync(recursive: true)) {
      expect(e.path.toLowerCase(), isNot(contains('rollback')), reason: e.path);
    }
  });

  test('only the debug-gated accessor reaches the image data', () {
    final List<String> importers = <String>[
      for (final FileSystemEntity e in Directory(
        'lib',
      ).listSync(recursive: true))
        if (e is File &&
            e.path.endsWith('.dart') &&
            e.readAsStringSync().contains('rollback_test_images.g.dart'))
          e.path,
    ];
    expect(importers, <String>[gate]);
    final String src = File(gate).readAsStringSync();
    expect(src, contains('const bool rollbackTestsAvailable = kDebugMode;'));
    // The data is referenced only after the constant guard.
    final int guard = src.indexOf('if (!kDebugMode) return null;');
    expect(guard, greaterThan(0));
    for (final String name in <String>[
      'rollbackTestFailImage',
      'rollbackTestFreezeImage',
      'rollbackTestFailManifest',
      'rollbackTestFreezeManifest',
    ]) {
      expect(src.indexOf(name), greaterThan(guard), reason: name);
    }
    expect(File(generated).existsSync(), isTrue);
  });

  test('the option is shown only where rollback tests are available', () {
    final String page = File(
      'lib/features/developer/light_developer_screen.dart',
    ).readAsStringSync();
    final int option = page.indexOf("'dev-rollback-test'");
    expect(option, greaterThan(0));
    expect(
      page.lastIndexOf('if (rollbackTestsAvailable)', option),
      greaterThan(0),
    );
    // Every other use of the images goes through the gated accessor.
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart') || e.path == gate) continue;
      expect(
        e.readAsStringSync(),
        isNot(contains('rollback_test_images')),
        reason: e.path,
      );
    }
  });

  test('in this (debug) build both images are there', () {
    expect(kDebugMode, isTrue);
    expect(rollbackTestsAvailable, isTrue);
    for (final RollbackTest t in RollbackTest.values) {
      expect(rollbackTestImage(t), isNotNull);
    }
  });
}
