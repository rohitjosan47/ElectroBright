import 'dart:io';

import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';

import 'fwsim_process.dart';

/// One randomised fw-in-the-loop case picked by an environment variable
/// (e.g. `DIFF_CASE=rgbcct:7`): the fixture (fwsim name) and the rest of the
/// fields after it. Null when [variable] is unset; a malformed value or an
/// unknown fixture throws, so a typo never runs the whole suite instead.
({EbFixtureSpec fixture, List<String> fields})? caseFromEnvironment(
  String variable, {
  required int fields,
}) {
  final String? raw = Platform.environment[variable]?.trim();
  if (raw == null || raw.isEmpty) return null;
  final List<String> parts = raw.split(':');
  final EbFixtureSpec? fixture = EbFixtureCatalog.all
      .where((EbFixtureSpec f) => f.fwsimName == parts.first)
      .firstOrNull;
  if (fixture == null || parts.length != fields + 1) {
    throw ArgumentError.value(raw, variable, 'expected <fixture>:… fields');
  }
  return (fixture: fixture, fields: parts.sublist(1));
}

/// Reports a failed (or abandoned) case: prints its fixture, seed, failing
/// step and how to re-run it alone, and saves [sim]'s full transcript (plus
/// [details]) to `build/test_failures/`.
Future<void> reportFwCaseFailure({
  required String test,
  required String fixture,
  required String seed,
  required String step,
  required Object error,
  required String rerun,
  FwSim? sim,
  String details = '',
}) async {
  final String header = <String>[
    'fw-in-the-loop failure: $test',
    '  fixture: $fixture',
    '  seed: $seed',
    '  failing step: $step',
    '  error: ${'$error'.split('\n').join('\n    ')}',
    '  re-run alone: $rerun',
  ].join('\n');
  String saved = '(no fwsim process)';
  if (sim != null) {
    try {
      saved = await sim.saveTranscript(
        '${test}_${fixture}_$seed'.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_'),
        header: '$header\n$details',
      );
    } on Object catch (e) {
      saved = '(could not save: $e)';
    }
  }
  // ignore: avoid_print
  print('$header\n  fwsim transcript: $saved');
}
