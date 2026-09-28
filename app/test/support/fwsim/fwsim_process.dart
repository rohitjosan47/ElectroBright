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
  FwSimReply(
    this.notifications,
    this.state,
    this.sounds,
    this.info, [
    this.otaNotifications = const <Uint8List>[],
  ]);

  /// Notifications the phone received, in order (each <= MTU-3 bytes).
  final List<Uint8List> notifications;

  /// Update-control notifications (`O <hex>` lines), in order.
  final List<Uint8List> otaNotifications;
  final Map<String, Object?>? state;
  final List<String>? sounds;
  final String? info;
}

/// Where fw-in-the-loop tests save the fwsim transcript of a failed case
/// (relative to the app package root).
const String testFailuresDir = 'build/test_failures';

/// Drives the real firmware core (fwsim) over stdin/stdout.
final class FwSim {
  FwSim._(this.fixture, this._process, this._lines, this._transcript);

  /// The fwsim fixture name (`--fixture`).
  final String fixture;
  final Process _process;
  final StreamIterator<String> _lines;

  /// Every request sent ("> ") and every stdout line received ("< "), in
  /// order.
  final List<String> _transcript;
  final StringBuffer _stderr = StringBuffer();
  int? _exitCode;

  /// Builds fwsim if needed (make is incremental) and starts it simulating
  /// [fixture] (`fwsim --fixture`, e.g. rgbw, rgb, rgbcct, cct, w).
  static Future<FwSim> start({String fixture = 'rgbw'}) async {
    await _ensureBuilt();
    final Process p = await Process.start(fwsimBinary, <String>[
      '--fixture',
      fixture,
    ]);
    final List<String> transcript = <String>[];
    final StreamIterator<String> lines = StreamIterator<String>(
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).map((
        String l,
      ) {
        transcript.add('< $l');
        return l;
      }),
    );
    final FwSim sim = FwSim._(fixture, p, lines, transcript);
    // Sanitizer banners and crash reports, never protocol: kept for the
    // failure transcript.
    p.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(sim._stderr.write);
    unawaited(p.exitCode.then((int code) => sim._exitCode = code));
    final FwSimReply hello = await sim.request('HELLO');
    if (hello.info == null || !hello.info!.startsWith('fwsim/1')) {
      throw StateError(
        'unexpected fwsim greeting: ${hello.info}\n${sim.transcript}',
      );
    }
    return sim;
  }

  /// Everything exchanged with this fwsim process so far: requests, replies,
  /// stderr and its exit code (if it has exited).
  String get transcript {
    final StringBuffer b = StringBuffer()
      ..writeln('fwsim --fixture $fixture (pid ${_process.pid})')
      ..writeln('exit code: ${_exitCode ?? 'still running'}')
      ..writeln('---- stdin (>) and stdout (<) ----')
      ..writeAll(_transcript, '\n')
      ..writeln()
      ..writeln('---- stderr ----')
      ..write(_stderr.isEmpty ? '(empty)\n' : _stderr);
    return b.toString();
  }

  /// Writes [header] and the [transcript] to `build/test_failures/<name>.log`
  /// and returns the file's path.
  Future<String> saveTranscript(String name, {String header = ''}) async {
    final File f = File('$testFailuresDir/$name.log');
    await f.parent.create(recursive: true);
    await f.writeAsString('$header\n$transcript');
    return f.path;
  }

  /// Ends the process without the QUIT handshake (a case abandoned mid-way).
  void kill() => _process.kill();

  /// Sends one request and collects its reply lines up to the "." terminator.
  Future<FwSimReply> request(String line) async {
    _transcript.add('> $line');
    _process.stdin.writeln(line);
    await _process.stdin.flush();
    final List<Uint8List> notes = <Uint8List>[];
    final List<Uint8List> otaNotes = <Uint8List>[];
    Map<String, Object?>? state;
    List<String>? sounds;
    String? info;
    while (true) {
      if (!await _lines.moveNext()) {
        // Let the exit code and the last stderr land in the transcript.
        _exitCode ??= await _process.exitCode
            .then<int?>((int c) => c)
            .timeout(const Duration(seconds: 2), onTimeout: () => null);
        throw StateError(
          'fwsim exited (code $_exitCode) while handling "$line"',
        );
      }
      final String l = _lines.current;
      if (l == '.') break;
      if (l.startsWith('N ')) {
        notes.add(_hex(l.substring(2)));
      } else if (l.startsWith('O ')) {
        otaNotes.add(_hex(l.substring(2)));
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
    return FwSimReply(notes, state, sounds, info, otaNotes);
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
