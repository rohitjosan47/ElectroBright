import 'dart:io';

import 'package:electrobright/core/store/json_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('eb-store'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('writes are batched, atomic and survive a reopen', () async {
    final JsonStore a = await JsonStore.open(dir);
    a.write('fixtures', <Object>[1, 2, 3]);
    a.write('settings', <String, Object>{'x': true});
    expect(a.read('fixtures'), <Object>[1, 2, 3]); // memory at once
    expect(
      File('${dir.path}/fixtures.json').existsSync(),
      isFalse,
    ); // disk later
    await a.flush();
    final JsonStore b = await JsonStore.open(dir);
    expect(b.read('fixtures'), <Object>[1, 2, 3]);
    expect(b.read('settings'), <String, Object>{'x': true});
    expect(
      dir.listSync().where((FileSystemEntity e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('a corrupt or missing file falls back to its backup', () async {
    final JsonStore a = await JsonStore.open(dir);
    a.write('fixtures', <Object>['first']);
    await a.flush();
    a.write('fixtures', <Object>['second']);
    await a.flush(); // first -> .bak
    File('${dir.path}/fixtures.json')
        .writeAsStringSync('{"schemaVersion":1,"da'); // torn write
    expect((await JsonStore.open(dir)).read('fixtures'), <Object>['first']);
    File('${dir.path}/fixtures.json').deleteSync();
    expect((await JsonStore.open(dir)).read('fixtures'), <Object>['first']);
  });

  test('the batch timer writes without an explicit flush', () async {
    final JsonStore a = await JsonStore.open(
      dir,
      writeDelay: const Duration(milliseconds: 10),
    );
    a.write('lastKnown', <String, Object>{'f1': 1});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect((await JsonStore.open(dir)).read('lastKnown'), <String, Object>{
      'f1': 1,
    });
  });
}
