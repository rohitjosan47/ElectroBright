import 'dart:io';

/// Firmware sources the app must agree with (paths relative to app/).
const String firmwareSrc = '../firmware/core/ElectroBrightCore/src';

/// Fixture sketches; each has a Fixture.h with its identity and wiring.
const String firmwareFixtures = '../firmware/fixtures';

/// The fixture the app's driver and Dart firmware twin currently implement.
const String appFixture = 'ElectroBright_RGBW';

String readFirmware(String relative, {String root = firmwareSrc}) {
  final File f = File('$root/$relative');
  if (!f.existsSync()) {
    throw StateError(
      'firmware source not found: ${f.path} (run tests from app/)',
    );
  }
  return f.readAsStringSync();
}

/// `constexpr <type> <name> = <value>;` from the core's Config.h plus the
/// fixture's Fixture.h (identity, wiring), numbers and strings.
Map<String, String> configConstants({String fixture = appFixture}) {
  final String src =
      readFirmware('config/Config.h') +
      readFirmware('$fixture/Fixture.h', root: firmwareFixtures);
  final RegExp decl = RegExp(
    r'constexpr\s+[\w:\s\*]+?\s+(k\w+)\s*=\s*("(?:[^"\\]|\\.)*"|[^;]+);',
  );
  return <String, String>{
    for (final RegExpMatch m in decl.allMatches(src))
      m.group(1)!: m.group(2)!.trim().replaceAll(RegExp(r'^"|"$'), ''),
  };
}

int configInt(Map<String, String> c, String name) {
  final String raw =
      c[name] ?? (throw StateError('$name missing in Config.h / Fixture.h'));
  return int.parse(raw.replaceAll(RegExp(r'[uUlL]+$'), ''));
}
