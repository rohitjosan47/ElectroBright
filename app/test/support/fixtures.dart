import 'dart:io';

import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';

/// The fixtures firmware-in-the-loop tests run against: every fixture of the
/// family, or those named in `FWSIM_FIXTURES` (comma-separated fwsim names,
/// e.g. `FWSIM_FIXTURES=cct,w`).
List<EbFixtureSpec> fixturesUnderTest() {
  final String? only = Platform.environment['FWSIM_FIXTURES'];
  if (only == null || only.trim().isEmpty) return EbFixtureCatalog.all;
  final Set<String> names = only.split(',').map((String s) => s.trim()).toSet();
  return EbFixtureCatalog.all
      .where((EbFixtureSpec f) => names.contains(f.fwsimName))
      .toList();
}
