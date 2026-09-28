import 'package:meta/meta.dart';

/// Why the light last started (DIAG `rst`, the ESP-IDF reset reason).
enum RestartReason {
  unknown,
  powerOn,
  resetPin,
  software,
  crash,
  interruptWatchdog,
  taskWatchdog,
  otherWatchdog,
  deepSleep,
  brownout,
  sdio,
  usb,
  jtag,
  efuse,
  powerGlitch,
  cpuLockup;

  /// `esp_reset_reason_t` in order; anything else is [unknown].
  static RestartReason of(int code) =>
      code >= 0 && code < values.length ? values[code] : unknown;
}

/// Which DIAG counters a row belongs to.
enum DiagGroup { render, connection, system, other }

/// The DIAG counters in the order and groups the developer page shows them
/// (firmware/README.md §7). Keys the app doesn't know go to [DiagGroup.other].
const Map<String, DiagGroup> diagCounters = <String, DiagGroup>{
  'frames': DiagGroup.render,
  'overrun': DiagGroup.render,
  'rmaxus': DiagGroup.render,
  'rx': DiagGroup.connection,
  'bin': DiagGroup.connection,
  'gaps': DiagGroup.connection,
  'binbad': DiagGroup.connection,
  'unk': DiagGroup.connection,
  'err': DiagGroup.connection,
  'coal': DiagGroup.connection,
  'ovf': DiagGroup.connection,
  'rej': DiagGroup.connection,
  'sdrop': DiagGroup.connection,
  'nretry': DiagGroup.connection,
  'edrop': DiagGroup.connection,
  'heapmin': DiagGroup.system,
  'stkc': DiagGroup.system,
  'stkr': DiagGroup.system,
  'nvsw': DiagGroup.system,
  'nvsf': DiagGroup.system,
  'endms': DiagGroup.system,
};

/// The keys shown in the summary rather than as counters.
const Set<String> diagSummaryKeys = <String>{'up', 'rst', 'slot', 'rb', 'pv'};

/// A DIAG reply, readable: the summary (uptime, last restart, running slot,
/// rollback, firmware check) and the counters by group, in the light's key order.
@immutable
final class DiagReport {
  const DiagReport(this.values);

  /// Every key and value the light sent, in its order.
  final Map<String, int> values;

  Duration? get uptime =>
      values['up'] == null ? null : Duration(seconds: values['up']!);
  RestartReason? get restart =>
      values['rst'] == null ? null : RestartReason.of(values['rst']!);

  /// The OTA app slot it runs from (3.8.0+).
  int? get slot => values['slot'];

  /// A rollback has happened since the rolled-back slot was last written
  /// (3.8.0+): an install since then clears it. Not "the last update".
  bool? get rolledBack => values['rb'] == null ? null : values['rb'] == 1;

  /// The running firmware is new and has not confirmed itself yet (3.8.2+):
  /// it refuses SET_TYPE, FACTORY_RESET and an update BEGIN as busy.
  bool? get pendingVerify => values['pv'] == null ? null : values['pv'] == 1;

  /// The counters of [group] (key, value) in the light's order; [DiagGroup
  /// .other] holds the keys the app doesn't know.
  List<(String, int)> counters(DiagGroup group) => <(String, int)>[
    for (final MapEntry<String, int> e in values.entries)
      if (!diagSummaryKeys.contains(e.key) &&
          (diagCounters[e.key] ?? DiagGroup.other) == group)
        (e.key, e.value),
  ];

  /// The reply as the light sent it.
  String get raw =>
      'DIAG:${values.entries.map((MapEntry<String, int> e) => '${e.key}=${e.value}').join(',')}';
}

/// A running time in the two largest units: "3 d 4 h", "2 h 5 min",
/// "4 min 12 s", "12 s".
String formatUptime(Duration d) {
  final int s = d.inSeconds;
  final int days = s ~/ 86400;
  final int hours = s % 86400 ~/ 3600;
  final int minutes = s % 3600 ~/ 60;
  final int seconds = s % 60;
  if (days > 0) return '$days d $hours h';
  if (hours > 0) return '$hours h $minutes min';
  if (minutes > 0) return '$minutes min $seconds s';
  return '$seconds s';
}
