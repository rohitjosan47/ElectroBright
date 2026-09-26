import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// The app's small database: one JSON file per collection in Application
/// Support, `{"schemaVersion": n, "data": ...}`.
///
/// Reads come from memory (loaded at [open]). Writes update memory at once
/// and reach disk batched ([writeDelay]) and atomically: a temporary file is
/// written and flushed, the previous file becomes `<name>.bak`, then the
/// temporary file is renamed into place. A missing or corrupt file falls back
/// to its backup.
final class JsonStore {
  JsonStore._(this.directory, this.writeDelay);

  /// A store that never touches disk (tests, previews).
  JsonStore.memory() : directory = null, writeDelay = Duration.zero;

  /// Opens (and creates) the store in [directory] and loads every collection.
  static Future<JsonStore> open(
    Directory directory, {
    Duration writeDelay = const Duration(milliseconds: 300),
  }) async {
    await directory.create(recursive: true);
    final JsonStore store = JsonStore._(directory, writeDelay);
    await for (final FileSystemEntity e in directory.list()) {
      final String name = e.uri.pathSegments.last;
      if (e is File && name.endsWith('.json')) {
        final String collection = name.substring(0, name.length - 5);
        final Object? data = await store._load(collection);
        if (data != null) store._cache[collection] = data;
      }
    }
    // Collections whose main file is gone but whose backup survived.
    await for (final FileSystemEntity e in directory.list()) {
      final String name = e.uri.pathSegments.last;
      if (e is File && name.endsWith('.json.bak')) {
        final String collection = name.substring(0, name.length - 9);
        if (!store._cache.containsKey(collection)) {
          final Object? data = await store._load(collection);
          if (data != null) store._cache[collection] = data;
        }
      }
    }
    return store;
  }

  static const int schemaVersion = 1;

  /// Null for [JsonStore.memory].
  final Directory? directory;
  final Duration writeDelay;
  final Map<String, Object?> _cache = <String, Object?>{};
  final Set<String> _dirty = <String>{};
  Timer? _timer;

  /// The last write that failed (the data stays in memory and is retried).
  FileSystemException? lastError;
  Future<void> _writing = Future<void>.value();

  /// The stored data of [collection], or null.
  Object? read(String collection) => _cache[collection];

  /// Replaces [collection] (written to disk within [writeDelay]).
  /// Writes requested so far (tests: how often the app persists).
  @visibleForTesting
  int writes = 0;

  void write(String collection, Object? data) {
    writes++;
    _cache[collection] = data;
    if (directory == null) return;
    _dirty.add(collection);
    _timer ??= Timer(writeDelay, () => unawaited(flush()));
  }

  /// Writes every pending change now (e.g. when the app goes to background).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final List<String> todo = _dirty.toList();
    _dirty.clear();
    _writing = _writing.then((_) async {
      for (final String c in todo) {
        try {
          await _save(c, _cache[c]);
        } on FileSystemException catch (e) {
          // Kept in memory and retried with the next write or flush.
          lastError = e;
          _dirty.add(c);
        }
      }
    });
    return _writing;
  }

  File _file(String c) => File('${directory!.path}/$c.json');
  File _bak(String c) => File('${directory!.path}/$c.json.bak');

  Future<Object?> _load(String c) async {
    for (final File f in <File>[_file(c), _bak(c)]) {
      try {
        if (!f.existsSync()) continue;
        final Object? json = jsonDecode(await f.readAsString());
        if (json is Map<String, Object?> && json['schemaVersion'] is int) {
          return json['data'];
        }
      } on FormatException {
        continue; // corrupt: try the backup
      }
    }
    return null;
  }

  Future<void> _save(String c, Object? data) async {
    final File tmp = File('${directory!.path}/$c.json.tmp');
    final RandomAccessFile raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(
        jsonEncode(<String, Object?>{
          'schemaVersion': schemaVersion,
          'data': data,
        }),
      );
      await raf.flush();
    } finally {
      await raf.close();
    }
    final File main = _file(c);
    if (main.existsSync()) await main.copy(_bak(c).path);
    await tmp.rename(main.path);
  }

  Future<void> close() => flush();
}
