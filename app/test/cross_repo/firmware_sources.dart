import 'dart:io';

/// Firmware sources the app must agree with (paths relative to app/).
const String firmwareSrc = '../firmware/core/ElectroBrightCore/src';

/// Fixture sketches; each has a Fixture.h with its identity and wiring.
const String firmwareFixtures = '../firmware/fixtures';

/// The fixture whose constants [configConstants] merges by default.
const String appFixture = 'ElectroBright_RGBW';

/// One fixture of firmware/test/Fixtures.h: fwsim name and sketch folder.
typedef FirmwareFixture = ({String name, String folder, String source});

/// Every fixture the firmware registers (kAllFixtures), with its Fixture.h.
List<FirmwareFixture> firmwareFixtureList() {
  final String registry = readFirmware('Fixtures.h', root: '../firmware/test');
  // namespace of each fixture folder, from its Fixture.h
  final Map<String, ({String folder, String source})> byNamespace =
      <String, ({String folder, String source})>{};
  for (final RegExpMatch m in RegExp(
    r'#include "(ElectroBright_\w+)/Fixture\.h"',
  ).allMatches(registry)) {
    final String folder = m.group(1)!;
    final String source = readFirmware(
      '$folder/Fixture.h',
      root: firmwareFixtures,
    );
    final String ns = RegExp(r'namespace fx \{\s*namespace (\w+) \{')
        .firstMatch(source)!
        .group(1)!;
    byNamespace[ns] = (folder: folder, source: source);
  }
  return <FirmwareFixture>[
    for (final RegExpMatch m in RegExp(
      r'\{"(\w+)", &fx::(\w+)::kProfile\}',
    ).allMatches(registry))
      (
        name: m.group(1)!,
        folder: byNamespace[m.group(2)!]!.folder,
        source: byNamespace[m.group(2)!]!.source,
      ),
  ];
}

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
