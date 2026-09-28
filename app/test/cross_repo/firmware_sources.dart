import 'dart:io';

/// Firmware sources the app must agree with (paths relative to app/).
const String firmwareSrc = '../firmware/core/ElectroBrightCore/src';

/// Fixture sketches: each installs the universal firmware and only chooses a
/// new light's type (`App::start(FixtureType::<T>)`).
const String firmwareFixtures = '../firmware/fixtures';

/// One fixture type of firmware/test/Fixtures.h: its fwsim name, the sketch
/// folder that makes it a new light's default, and its entry of the core's
/// profile table (fixture/Profiles.h, `inline constexpr FixtureProfile k…{…};`).
typedef FirmwareFixture = ({String name, String folder, String source});

/// The profile-table entry `k<name>` of fixture/Profiles.h, braces included.
String profileSource(String name) {
  final String table = readFirmware('fixture/Profiles.h');
  final RegExpMatch? m = RegExp(
    'inline constexpr FixtureProfile k$name\\{.*?\\n\\};',
    dotAll: true,
  ).firstMatch(table);
  if (m == null) throw StateError('profile k$name not found in Profiles.h');
  return m.group(0)!;
}

/// Every fixture type the firmware registers (kAllFixtures).
List<FirmwareFixture> firmwareFixtureList() {
  final String registry = readFirmware('Fixtures.h', root: '../firmware/test');
  // FixtureType of each sketch's first install -> its folder.
  final Map<String, String> folderByType = <String, String>{};
  for (final FileSystemEntity e in Directory(firmwareFixtures).listSync()) {
    if (e is! Directory) continue;
    final String folder = e.uri.pathSegments.lastWhere(
      (String x) => x.isNotEmpty,
    );
    final File ino = File('${e.path}/$folder.ino');
    if (!ino.existsSync()) continue;
    final RegExpMatch? m = RegExp(r'App::start\(FixtureType::(\w+)\)')
        .firstMatch(ino.readAsStringSync());
    if (m != null) folderByType[m.group(1)!] = folder;
  }
  return <FirmwareFixture>[
    for (final RegExpMatch m in RegExp(
      r'\{"(\w+)", &profiles::k(\w+)\}',
    ).allMatches(registry))
      () {
        final String source = profileSource(m.group(2)!);
        final String type = RegExp(r'FixtureType::(\w+)')
            .firstMatch(source)!
            .group(1)!;
        return (
          name: m.group(1)!,
          folder: folderByType[type] ?? '(no sketch)',
          source: source,
        );
      }(),
  ];
}

/// The string literals of a profile entry, in order (model id, BLE name).
List<String> profileStrings(String source) => <String>[
  for (final RegExpMatch m in RegExp(r'"([^"]*)"').allMatches(source))
    m.group(1)!,
];

String readFirmware(String relative, {String root = firmwareSrc}) {
  final File f = File('$root/$relative');
  if (!f.existsSync()) {
    throw StateError(
      'firmware source not found: ${f.path} (run tests from app/)',
    );
  }
  return f.readAsStringSync();
}

/// `constexpr <type> <name> = <value>;` from the core's Config.h, numbers
/// and strings.
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

/// The CAPS reply of profile [layout] (protocol/Replies.cpp replies::caps):
/// the fixed fields, TYPES= in profile-table order, PROBE=1, LAYOUT= and
/// MODES= when the layout lacks a mode. The light itself ends it with
/// `,OTA=<bytes>` (its update slot): pass [otaBytes] for the whole reply;
/// without it, the per-profile part the fixture catalogue holds.
String firmwareCaps(String layout, int modeMask, {int? otaBytes}) {
  final String replies = readFirmware('protocol/Replies.cpp');
  const String head =
      'CAPS:PROTOCOL=1,PWM=%u,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=%u,IDENTIFY=1,TYPES=';
  for (final String piece in <String>[
    head,
    ',PROBE=1,LAYOUT=%s',
    ',MODES=%X',
    ',OTA=%lu',
  ]) {
    if (!replies.contains(piece)) {
      throw StateError('Replies.cpp CAPS format changed: $piece');
    }
  }
  final Map<String, String> c = configConstants();
  final int pwm = configInt(c, 'kPwmBits') + configInt(c, 'kPwmDitherBits');
  final String modes = modeMask == 0x1FFF || layout == 'NONE'
      ? ''
      : ',MODES=${modeMask.toRadixString(16).toUpperCase()}';
  return 'CAPS:PROTOCOL=1,PWM=$pwm,GAMMA=2.2,MASTER=PERCEPTUAL,'
      'PRESETS=${configInt(c, 'kNumPresets')},IDENTIFY=1,'
      'TYPES=${firmwareTypes().join(',')},PROBE=1,LAYOUT=$layout$modes'
      '${otaBytes == null ? '' : ',OTA=$otaBytes'}';
}

/// Layout names of profiles::kAll, in order (CAPS TYPES=).
List<String> firmwareTypes() {
  final String table = readFirmware('fixture/Profiles.h');
  final String all = RegExp(r'kAll\[\] = \{([^}]*)\}')
      .firstMatch(table)!
      .group(1)!;
  return <String>[
    for (final RegExpMatch m in RegExp(r'&k(\w+)').allMatches(all))
      RegExp(r'&layouts::k(\w+),')
          .firstMatch(profileSource(m.group(1)!))!
          .group(1)!
          .toUpperCase(),
  ];
}

/// Supported-mode mask of layout [name] in ChannelLayout.h: every mode except
/// those removed with `~modeBit(kModeX)`.
int firmwareModeMask(String name) {
  final String src = readFirmware('fixture/ChannelLayout.h');
  final String row = RegExp(
    'inline constexpr ChannelLayout k\\w+\\{"$name"[^\\n]*',
  ).firstMatch(src)!.group(0)!;
  int mask = 0x1FFF;
  for (final RegExpMatch m in RegExp(r'~modeBit\((\w+)\)').allMatches(row)) {
    final int mode = int.parse(
      RegExp('constexpr uint8_t ${m.group(1)} = (\\d+);')
          .firstMatch(src)!
          .group(1)!,
    );
    mask &= ~(1 << (mode - 1));
  }
  return row.contains('{}, 0}') ? 0 : mask;
}

int configInt(Map<String, String> c, String name) {
  final String raw = c[name] ?? (throw StateError('$name missing in Config.h'));
  return int.parse(raw.replaceAll(RegExp(r'[uUlL]+$'), ''));
}
