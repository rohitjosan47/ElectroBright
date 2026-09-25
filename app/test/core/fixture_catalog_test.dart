import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// White LED temperatures are product data in the fixture catalog.
void main() {
  test('every product states its white points', () {
    expect(EbFixtureCatalog.rgbw.whitePoints.wK, 4000);
    expect(EbFixtureCatalog.w.whitePoints.wK, 4000);
    for (final EbFixtureSpec f in <EbFixtureSpec>[
      EbFixtureCatalog.cct,
      EbFixtureCatalog.rgbcct,
    ]) {
      expect(f.whitePoints.cwK, 6500, reason: '$f');
      expect(f.whitePoints.wwK, 2700, reason: '$f');
    }
    for (final EbFixtureSpec f in EbFixtureCatalog.all) {
      expect(f.whitePoints.isValid, isTrue, reason: '$f');
    }
  });

  test('forModel finds a model id, nothing else', () {
    expect(EbFixtureCatalog.forModel('EB-C3-CCT-V1'), EbFixtureCatalog.cct);
    expect(EbFixtureCatalog.forModel('EB-C3-CCT-V9'), isNull);
    expect(EbFixtureCatalog.forModel(null), isNull);
  });

  test('whitePointsFor: the model first, else the layout', () {
    for (final EbFixtureSpec f in EbFixtureCatalog.all) {
      // Known model: its values, whatever layout is passed.
      expect(
        EbFixtureCatalog.whitePointsFor(
          modelId: f.modelId,
          layout: ChannelLayout.rgb,
        ),
        f.whitePoints,
        reason: '$f',
      );
      // Unknown or missing model: the layout's product.
      expect(
        EbFixtureCatalog.whitePointsFor(
          modelId: 'EB-C3-FUTURE-V2',
          layout: f.layout,
        ),
        f.whitePoints,
        reason: '$f',
      );
      expect(
        EbFixtureCatalog.whitePointsFor(layout: f.layout),
        f.whitePoints,
        reason: '$f',
      );
    }
    expect(
      EbFixtureCatalog.whitePointsFor(layout: ChannelLayout.cct),
      const LedWhitePoints(cwK: 6500, wwK: 2700),
    );
  });
}
