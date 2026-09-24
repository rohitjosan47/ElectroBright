import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads real fonts so goldens show text and icons instead of Ahem boxes.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final FontLoader inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
  await inter.load();
  final String? root = Platform.environment['FLUTTER_ROOT'];
  final File icons = File(
    '${root ?? _flutterRoot()}/bin/cache/artifacts/material_fonts/'
    'MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final FontLoader material = FontLoader('MaterialIcons')
      ..addFont(
        Future<ByteData>.value(ByteData.sublistView(icons.readAsBytesSync())),
      );
    await material.load();
  }
  await testMain();
}

String _flutterRoot() {
  // `flutter test` runs the tester from <flutter>/bin/cache/...
  final String exe = Platform.resolvedExecutable;
  final int i = exe.indexOf('/bin/cache/');
  return i < 0 ? '' : exe.substring(0, i);
}
