import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Path of the firmware test directory, relative to the app package root
/// (flutter test runs with the package root as the working directory).
const String firmwareTestDir = '../firmware/test';
const String fwsimBinary = '$firmwareTestDir/build/fwsim/fwsim';

/// One reply to an fwsim request (see firmware/test/fwsim/main.cpp).
final class FwSimReply {
  FwSimReply(this.notifications, this.state, this.sounds, this.info);

  /// Notifications the phone received, in order (each <= MTU-3 bytes).
  final List<Uint8List> notifications;
  final Map<String, Object?>? state;
  final List<String>? sounds;
  final String? info;
}

/// Drives the real firmware core (fwsim) over stdin/stdout.
final class FwSim {
  FwSim._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;

  /// Builds fwsim if needed (make is incremental) and starts it simulating
  /// [fixture] (`fwsim --fixture`, e.g. rgbw, rgb, rgbcct, cct, w).
  static Future<FwSim> start({String fixture = 'rgbw'}) async {
    await _ensureBuilt();
    final Process p = await Process.start(fwsimBinary, <String>[
      '--fixture',
      fixture,
    ]);
    unawaited(p.stderr.drain<void>()); // sanitizer banners, never protocol
    final StreamIterator<String> lines = StreamIterator<String>(
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final FwSim sim = FwSim._(p, lines);
    final FwSimReply hello = await sim.request('HELLO');
    if (hello.info == null || !hello.info!.startsWith('fwsim/1')) {
      throw StateError('unexpected fwsim greeting: ${hello.info}');
    }
    return sim;
  }

  /// Sends one request and collects its reply lines up to the "." terminator.
  Future<FwSimReply> request(String line) async {
    _process.stdin.writeln(line);
    await _process.stdin.flush();
    final List<Uint8List> notes = <Uint8List>[];
    Map<String, Object?>? state;
    List<String>? sounds;
    String? info;
    while (true) {
      if (!await _lines.moveNext()) {
        throw StateError('fwsim exited while handling "$line"');
      }
      final String l = _lines.current;
      if (l == '.') break;
      if (l.startsWith('N ')) {
        notes.add(_hex(l.substring(2)));
      } else if (l.startsWith('S ')) {
        state = jsonDecode(l.substring(2)) as Map<String, Object?>;
      } else if (l.startsWith('B')) {
        final String body = l.length > 2 ? l.substring(2) : '';
        sounds = body.isEmpty ? <String>[] : body.split(',');
      } else if (l.startsWith('I ')) {
        info = l.substring(2);
      } else if (l.startsWith('! ')) {
        throw StateError('fwsim rejected "$line": ${l.substring(2)}');
      } else {
        throw StateError('unexpected fwsim output: $l');
      }
    }
    return FwSimReply(notes, state, sounds, info);
  }

  Future<FwSimReply> write(List<int> bytes) => request('W ${_toHex(bytes)}');

  Future<Map<String, Object?>> state() async => (await request('STATE')).state!;

  Future<void> close() async {
    _process.stdin.writeln('QUIT');
    await _process.stdin.close();
    await _process.exitCode;
    await _lines.cancel();
  }

  static Uint8List _hex(String s) {
    final Uint8List out = Uint8List(s.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
    }
    return out;
  }

  static String _toHex(List<int> bytes) => bytes
      .map((int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();

  // flutter test runs test files in parallel processes; serialise `make` with
  // an exclusive lock file so concurrent builds never race on the same objects.
  static Future<void> _ensureBuilt() async {
    await Directory('$firmwareTestDir/build').create(recursive: true);
    final File lock = File('$firmwareTestDir/build/.fwsim-build.lock');
    for (int attempt = 0; ; attempt++) {
      try {
        await lock.create(exclusive: true);
        break;
      } on FileSystemException {
        // A crashed build must not block every later run.
        final DateTime? since = lock.existsSync()
            ? lock.lastModifiedSync()
            : null;
        if (since != null &&
            DateTime.now().difference(since) > const Duration(minutes: 3)) {
          lock.deleteSync();
          continue;
        }
        if (attempt > 3000) throw StateError('fwsim build lock stuck: $lock');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    try {
      final ProcessResult r = await Process.run('make', <String>[
        '-C',
        firmwareTestDir,
        '--no-print-directory',
        'fwsim',
      ]);
      if (r.exitCode != 0) {
        throw StateError('building fwsim failed:\n${r.stdout}\n${r.stderr}');
      }
    } finally {
      if (lock.existsSync()) lock.deleteSync();
    }
  }
}
