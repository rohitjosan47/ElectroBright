import 'package:electrobright/core/protocol/eb/mode_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'firmware_sources.dart';

/// The app's mode catalogue must equal the firmware's ModeRegistry.h:
/// ids, names, which sliders exist, colour-mode support and slider labels.
void main() {
  test('EbModeCatalog matches firmware ModeRegistry.h', () {
    final RegExp row = RegExp(
      r'\{\s*(\d+),\s*"([^"]+)",\s*(true|false),\s*(true|false),\s*(true|false),'
      r'\s*(nullptr|"[^"]*"),\s*(nullptr|"[^"]*")\}',
    );
    final List<RegExpMatch> rows = row
        .allMatches(readFirmware('render/ModeRegistry.h'))
        .toList();
    expect(rows.length, EbModeCatalog.modes.length);
    String? label(String raw) =>
        raw == 'nullptr' ? null : raw.substring(1, raw.length - 1);
    for (final RegExpMatch m in rows) {
      final EbModeSpec app = EbModeCatalog.byId(int.parse(m.group(1)!));
      final String id = 'mode ${app.id}';
      expect(app.id, int.parse(m.group(1)!), reason: id);
      expect(app.name, m.group(2), reason: id);
      expect(app.hasSpeed, m.group(3) == 'true', reason: '$id speed');
      expect(app.hasFrequency, m.group(4) == 'true', reason: '$id frequency');
      expect(app.hasColorMode, m.group(5) == 'true', reason: '$id colour mode');
      expect(
        app.speedLabel,
        app.hasSpeed ? label(m.group(6)!) : null,
        reason: id,
      );
      expect(
        app.frequencyLabel,
        app.hasFrequency ? label(m.group(7)!) : null,
        reason: id,
      );
    }
  });
}
