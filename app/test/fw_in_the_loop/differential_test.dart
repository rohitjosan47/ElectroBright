// The Dart firmware twin (lib/sim/eb_device_model.dart) must behave exactly
// like the real firmware core (fwsim): same reply bytes, same notification
// chunking, same state, same sounds — for valid, invalid, fragmented and
// garbage traffic, arbitrary control-pass scheduling and injected faults.
@Tags(<String>['fwsim'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fwsim/fwsim_process.dart';

const DeepCollectionEquality _deep = DeepCollectionEquality();

void main() {
  final int seeds =
      int.tryParse(Platform.environment['FWSIM_SEEDS'] ?? '') ?? 40;
  const int opsPerSeed = 500;

  test('firmware twin matches fwsim on $seeds random traffic runs', () async {
    for (int seed = 1; seed <= seeds; seed++) {
      final FwSim sim = await FwSim.start(); // fresh device per seed
      try {
        await _runSeed(sim, seed, opsPerSeed);
      } finally {
        await sim.close();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<void> _runSeed(FwSim sim, int seed, int ops) async {
  // Both sides start freshly booted at t = 1000 ms with empty flash; the test
  // schedules every control pass explicitly.
  await sim.request('AUTO 0');
  final EbDeviceModel model = EbDeviceModel()..takeSounds();
  expect(model.now, (await sim.state())['now']);

  final _Traffic traffic = _Traffic(seed);
  final List<String> log = <String>[];
  bool splitOpen = false;

  Future<void> both(String request, void Function() onModel) async {
    log.add(request);
    final FwSimReply r = await sim.request(request);
    onModel();
    final List<String> want = r.notifications.map(_hex).toList();
    final List<String> got = model.takeNotifications().map(_hex).toList();
    if (!_deep.equals(want, got)) {
      fail(
        'seed $seed: notifications differ after "$request"\n'
        '  fwsim: ${want.map(_ascii).toList()}\n'
        '  model: ${got.map(_ascii).toList()}\n'
        '  last ops: ${log.skip(max(0, log.length - 15)).toList()}',
      );
    }
  }

  Future<void> compareState(String when) async {
    final Map<String, Object?> want = await sim.state();
    final Object? got = jsonDecode(jsonEncode(model.state()));
    if (!_deep.equals(want, got)) {
      fail(
        'seed $seed: state differs $when\n  fwsim: $want\n  model: $got\n'
        '  last ops: ${log.skip(max(0, log.length - 15)).toList()}',
      );
    }
  }

  for (int i = 0; i < ops; i++) {
    final _Op op = traffic.next(connected: model.connected);
    switch (op) {
      case _Write(:final List<int> bytes):
        await both('W ${_hex(bytes)}', () => model.write(bytes));
      case _Pass():
        if (splitOpen) {
          await both('END', model.passEnd);
          splitOpen = false;
        } else {
          await both('PASS', model.pass);
        }
      case _Begin():
        if (!splitOpen) {
          await both('BEGIN', model.passBegin);
          splitOpen = true;
        }
      case _Advance(:final int ms):
        if (splitOpen) {
          await both('END', model.passEnd);
          splitOpen = false;
        }
        await both('ADV $ms', () => model.advance(ms));
      case _Connect():
        await both('CONNECT', model.connect);
      case _Disconnect():
        await both('DISCONNECT', model.disconnect);
      case _Subscribe(:final bool on):
        await both(
          'SUB ${on ? 1 : 0}',
          () => model.setSubscribed(subscribed: on),
        );
      case _Mtu(:final int mtu):
        await both('MTU $mtu', () => model.setMtu(mtu));
      case _NotifyFail(:final int count):
        await both('NFAIL $count', () => model.failNextNotifies(count));
      case _FlashFail(:final bool on):
        await both('KVFAIL ${on ? 1 : 0}', () => model.flashWritesFail = on);
      case _Reboot():
        splitOpen = false;
        await both('REBOOT', () {
          model
            ..reboot()
            ..takeSounds();
        });
      case _CheckSounds():
        final List<String> want = (await sim.request('SOUNDS')).sounds!;
        final List<String> got = model.takeSounds();
        expect(got, want, reason: 'seed $seed: sounds differ');
      case _CheckState():
        await compareState('at op $i');
    }
  }
  if (splitOpen) await both('END', model.passEnd);
  await compareState('at the end');
}

// ---- Traffic generator ------------------------------------------------------------------

sealed class _Op {
  const _Op();
}

final class _Write extends _Op {
  const _Write(this.bytes);
  final List<int> bytes;
}

final class _Pass extends _Op {
  const _Pass();
}

final class _Begin extends _Op {
  const _Begin();
}

final class _Advance extends _Op {
  const _Advance(this.ms);
  final int ms;
}

final class _Connect extends _Op {
  const _Connect();
}

final class _Disconnect extends _Op {
  const _Disconnect();
}

final class _Subscribe extends _Op {
  const _Subscribe({required this.on});
  final bool on;
}

final class _Mtu extends _Op {
  const _Mtu(this.mtu);
  final int mtu;
}

final class _NotifyFail extends _Op {
  const _NotifyFail(this.count);
  final int count;
}

final class _FlashFail extends _Op {
  const _FlashFail({required this.on});
  final bool on;
}

final class _Reboot extends _Op {
  const _Reboot();
}

final class _CheckSounds extends _Op {
  const _CheckSounds();
}

final class _CheckState extends _Op {
  const _CheckState();
}

final class _Traffic {
  _Traffic(int seed) : _r = Random(seed);

  final Random _r;
  final List<List<int>> _pendingFragments = <List<int>>[];
  bool _subscribed = false;

  _Op next({required bool connected}) {
    if (_pendingFragments.isNotEmpty && _r.nextDouble() < 0.7) {
      return _Write(_pendingFragments.removeAt(0));
    }
    if (!connected && _r.nextDouble() < 0.3) return const _Connect();
    if (connected && !_subscribed && _r.nextDouble() < 0.5) {
      _subscribed = true;
      return const _Subscribe(on: true);
    }
    final double x = _r.nextDouble();
    if (x < 0.46) return _Write(_writeBytes());
    if (x < 0.66) return const _Pass();
    if (x < 0.71) return const _Begin();
    if (x < 0.79) {
      const List<int> steps = <int>[10, 50, 120, 400, 1000, 2100, 3100, 16000];
      return _Advance(steps[_r.nextInt(steps.length)]);
    }
    if (x < 0.82) {
      const List<int> mtus = <int>[23, 27, 50, 100, 185, 247, 517];
      return _Mtu(mtus[_r.nextInt(mtus.length)]);
    }
    if (x < 0.835) {
      _subscribed = false;
      return const _Disconnect();
    }
    if (x < 0.85) {
      _subscribed = _r.nextBool();
      return _Subscribe(on: _subscribed);
    }
    if (x < 0.865) return _NotifyFail(1 + _r.nextInt(3));
    if (x < 0.88) return _FlashFail(on: _r.nextDouble() < 0.4);
    if (x < 0.884) {
      _subscribed = false;
      return const _Reboot();
    }
    if (x < 0.92) return const _CheckSounds();
    return const _CheckState();
  }

  List<int> _writeBytes() {
    final double x = _r.nextDouble();
    if (x < 0.40) return _line(_validCommand());
    if (x < 0.50) return _line(_invalidCommand());
    if (x < 0.58) {
      // A command split over several writes.
      final List<int> whole = _line(_validCommand());
      final int cuts = 1 + _r.nextInt(2);
      final List<int> points = List<int>.generate(
        cuts,
        (_) => 1 + _r.nextInt(max(1, whole.length - 1)),
      )..sort();
      int start = 0;
      final List<List<int>> parts = <List<int>>[];
      for (final int p in points) {
        if (p > start) parts.add(whole.sublist(start, p));
        start = p;
      }
      parts.add(whole.sublist(start));
      _pendingFragments.addAll(parts.skip(1));
      return parts.first;
    }
    if (x < 0.70) return _frame8();
    if (x < 0.74) return _legacyFrame();
    if (x < 0.78) return _badFrame();
    if (x < 0.83) {
      // Garbage, control bytes, non-ASCII.
      return List<int>.generate(1 + _r.nextInt(30), (_) => _r.nextInt(256));
    }
    if (x < 0.86) {
      return <int>[
        ...List<int>.generate(
          97 + _r.nextInt(120),
          (_) => 0x41 + _r.nextInt(26),
        ),
        0x0A,
      ];
    }
    if (x < 0.93) {
      // A burst of lines in one write (batch coalescing).
      final StringBuffer b = StringBuffer();
      for (int i = 0; i < 2 + _r.nextInt(6); i++) {
        b.write(_r.nextBool() ? _validCommand() : _coalescible());
        b.write('\n');
      }
      return utf8.encode(b.toString());
    }
    if (x < 0.945) {
      // Reply-heavy burst: overflows the 1 KB reply buffer within one pass,
      // so the oldest replies must be evicted exactly like the firmware does.
      final String q = <String>[
        'DIAG',
        'STATUS',
        'MODE_SETTINGS',
      ][_r.nextInt(3)];
      return utf8.encode('$q\n' * (6 + _r.nextInt(12)));
    }
    if (x < 0.96) {
      // Large write: may overflow the 1024-byte stream when passes lag.
      return utf8.encode(
        '${List<String>.generate(20, (_) => _coalescible()).join('\n')}\n',
      );
    }
    return <int>[0x0A];
  }

  List<int> _line(String s) {
    final double t = _r.nextDouble();
    final String term = t < 0.85
        ? '\n'
        : t < 0.93
        ? '\r\n'
        : '\r';
    return utf8.encode('$s$term');
  }

  int _b() => _r.nextInt(256);
  int _lvl() => 1 + _r.nextInt(10);
  int _mode() => 1 + _r.nextInt(13);
  int _slot() => _r.nextInt(25);

  String _coalescible() => switch (_r.nextInt(4)) {
    0 => 'RGBW:${_b()},${_b()},${_b()},${_b()}',
    1 => 'BRIGHTNESS:${_b()}',
    2 => 'SPEED:${_lvl()}',
    _ => 'FREQUENCY:${_lvl()}',
  };

  String _validCommand() {
    final String cmd = switch (_r.nextInt(32)) {
      0 => 'RGBW:${_b()},${_b()},${_b()},${_b()}',
      1 => 'COLOR:${_b()},${_b()},${_b()},${_b()}',
      2 => 'BRIGHTNESS:${_b()}',
      3 => 'MODE:${_mode()}',
      4 => 'SPEED:${_lvl()}',
      5 => 'FREQUENCY:${_lvl()}',
      6 => 'FIREWORK_COLOR_MODE:${_r.nextInt(2)}',
      7 => 'CLUB_COLOR_MODE:${_r.nextInt(2)}',
      8 => 'POLICE_COLOR_MODE:${_r.nextInt(2)}',
      9 => 'POLICE_COLOR_A:${_b()},${_b()},${_b()},${_b()}',
      10 => 'POLICE_COLOR_B:${_b()},${_b()},${_b()},${_b()}',
      11 => 'PRESET_SAVE:${_slot()}',
      12 => 'PRESET_LOAD:${_slot()}',
      13 => 'PRESET_DELETE:${_slot()}',
      14 => 'PRESET_LIST',
      15 => 'STATUS',
      16 => 'MODE_SETTINGS',
      17 => 'MODE_SPEED:${_mode()},${_lvl()}',
      18 => 'MODE_FREQUENCY:${_mode()},${_lvl()}',
      19 => 'MODE_CAPABILITIES:${_mode()}',
      20 => 'SLEEP',
      21 => 'WAKE',
      22 => 'SOUND_ON',
      23 => 'SOUND_OFF',
      24 => 'TIMER:${_r.nextDouble() < 0.2 ? 0 : 1 + _r.nextInt(5)}',
      25 => _r.nextDouble() < 0.1 ? 'FACTORY_RESET' : 'PING',
      26 => 'INFO',
      27 => 'VERSION',
      28 => 'CAPS',
      29 => 'PING',
      30 => 'DIAG',
      _ => 'TIMER:${_r.nextInt(86401)}',
    };
    return _decorate(cmd);
  }

  /// Case, whitespace and trailing-comma variations the parser accepts.
  String _decorate(String cmd) {
    String s = cmd;
    if (_r.nextDouble() < 0.15) s = s.toLowerCase();
    if (_r.nextDouble() < 0.1) s = ' $s ';
    if (_r.nextDouble() < 0.1) s = s.replaceAll(',', ' , ');
    if (_r.nextDouble() < 0.08) s = s.replaceFirst(':', ' : ');
    if (_r.nextDouble() < 0.05 && s.contains(':')) s = '$s,';
    if (_r.nextDouble() < 0.05) s = s.replaceAll(' ', '\t');
    if (_r.nextDouble() < 0.05 && !s.contains(':')) s = '$s:';
    return s;
  }

  String _invalidCommand() => switch (_r.nextInt(14)) {
    0 => 'MODE:${_r.nextBool() ? 0 : 14 + _r.nextInt(100)}',
    1 => 'SPEED:${_r.nextBool() ? 0 : 11}',
    2 => 'BRIGHTNESS:256',
    3 => 'RGBW:1,2,3',
    4 => 'RGBW:1,2,3,4,5',
    5 => 'STATUS:5',
    6 => 'MODE:x',
    7 => 'MODE:-1',
    8 => 'TIMER:99999999999',
    9 => 'NOT_A_COMMAND',
    10 => 'MODE_SPEED:3',
    11 => 'PRESET_LOAD:25',
    12 => 'POLICE_COLOR_A:1,2,3,256',
    _ => 'MODE:',
  };

  List<int> _frame8() {
    final int seq = _r.nextInt(256);
    final List<int> v = <int>[_b(), _b(), _b(), _b(), _b()];
    return <int>[
      0xAA,
      seq,
      ...v,
      seq ^ v[0] ^ v[1] ^ v[2] ^ v[3] ^ v[4] ^ 0x55,
    ];
  }

  List<int> _legacyFrame() {
    if (_r.nextBool()) {
      final List<int> v = <int>[_b(), _b(), _b(), _b(), _b()];
      return <int>[0xAA, ...v, v[0] ^ v[1] ^ v[2] ^ v[3] ^ v[4] ^ 0x55];
    }
    final List<int> v = <int>[_b(), _b(), _b(), _b()];
    return <int>[0xAA, ...v, v[0] ^ v[1] ^ v[2] ^ v[3] ^ 0x55];
  }

  List<int> _badFrame() {
    final List<int> f = _frame8();
    f[7] ^= 1 + _r.nextInt(255);
    return f;
  }
}

String _hex(List<int> bytes) => bytes
    .map((int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join();

String _ascii(String hex) {
  final Uint8List b = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < b.length; i++) {
    b[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return String.fromCharCodes(b).replaceAll('\n', r'\n');
}
