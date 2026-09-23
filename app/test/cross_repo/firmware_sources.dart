import 'dart:io';

/// Firmware sources the app must agree with (paths relative to app/).
const String firmwareSrc = '../firmware/ElectroBright/src';

String readFirmware(String relative) {
  final File f = File('$firmwareSrc/$relative');
  if (!f.existsSync()) {
    throw StateError(
      'firmware source not found: ${f.path} (run tests from app/)',
    );
  }
  return f.readAsStringSync();
}

/// `constexpr <type> <name> = <value>;` from Config.h (numbers and strings).
Map<String, String> configConstants() {
  final String src = readFirmware('config/Config.h');
  final RegExp decl = RegExp(
    r'constexpr\s+[\w:\s\*]+?\s+(k\w+)\s*=\s*("(?:[^"\\]|\\.)*"|[^;]+);',
  );
  return <String, String>{
    for (final RegExpMatch m in decl.allMatches(src))
      m.group(1)!: m.group(2)!.trim().replaceAll(RegExp(r'^"|"$'), ''),
  };
}

int configInt(Map<String, String> c, String name) {
  final String raw = c[name] ?? (throw StateError('$name missing in Config.h'));
  return int.parse(raw.replaceAll(RegExp(r'[uUlL]+$'), ''));
}
