import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:electrobright_app/features/dashboard/domain/mode_definition.dart';

/// Guards against the app and the firmware drifting apart: the firmware's
/// mode registry (capabilities + slider names) must match ModeDefinition.
void main() {
  const registryPath = '../firmware/ElectroBright/src/render/ModeRegistry.h';

  test('ModeDefinition matches firmware ModeRegistry.h', () {
    final file = File(registryPath);
    expect(file.existsSync(), isTrue, reason: 'firmware registry not found at $registryPath');

    final row = RegExp(
      r'\{\s*(\d+),\s*"([^"]+)",\s*(true|false),\s*(true|false),\s*(true|false),\s*(nullptr|"[^"]*"),\s*(nullptr|"[^"]*")\}',
    );
    final rows = row.allMatches(file.readAsStringSync()).toList();
    expect(rows.length, ModeDefinition.allModes.length);

    String? label(String raw) => raw == 'nullptr' ? null : raw.substring(1, raw.length - 1);

    for (final m in rows) {
      final id = int.parse(m.group(1)!);
      final app = ModeDefinition.getById(id);
      expect(app.id, id);
      expect(app.hasSpeed, m.group(3) == 'true', reason: 'hasSpeed mismatch for mode $id');
      expect(app.hasFrequency, m.group(4) == 'true', reason: 'hasFrequency mismatch for mode $id');
      expect(app.hasColorMode, m.group(5) == 'true', reason: 'hasColorMode mismatch for mode $id');
      if (app.hasSpeed) expect(app.speedLabel, label(m.group(6)!), reason: 'speed label for mode $id');
      if (app.hasFrequency) {
        expect(app.frequencyLabel, label(m.group(7)!), reason: 'frequency label for mode $id');
      }
    }
  });
}
