import 'package:meta/meta.dart';

/// Colour temperatures of a light's white LEDs, in Kelvin (editable per
/// light under LED calibration). Used to preview the light's output and to
/// mix cool/warm white for a requested colour temperature.
@immutable
final class LedWhitePoints {
  const LedWhitePoints({this.wK = 4000, this.cwK = 6500, this.wwK = 2700});

  /// The single white LED (RGBW, W).
  final int wK;

  /// Cool white LED (CCT, RGBCCT).
  final int cwK;

  /// Warm white LED (CCT, RGBCCT).
  final int wwK;

  static const int minK = 1500;
  static const int maxK = 10000;

  /// CW must be clearly cooler than WW for a usable temperature range.
  static const int minSpanK = 500;

  bool get isValid =>
      _inRange(wK) && _inRange(cwK) && _inRange(wwK) && cwK - wwK >= minSpanK;

  static bool _inRange(int k) => k >= minK && k <= maxK;

  LedWhitePoints copyWith({int? wK, int? cwK, int? wwK}) => LedWhitePoints(
    wK: wK ?? this.wK,
    cwK: cwK ?? this.cwK,
    wwK: wwK ?? this.wwK,
  );

  Map<String, int> toJson() => <String, int>{'w': wK, 'cw': cwK, 'ww': wwK};

  static LedWhitePoints fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const LedWhitePoints();
    int k(String key, int fallback) {
      final Object? v = json[key];
      return v is int && _inRange(v) ? v : fallback;
    }

    final LedWhitePoints p = LedWhitePoints(
      wK: k('w', 4000),
      cwK: k('cw', 6500),
      wwK: k('ww', 2700),
    );
    return p.isValid ? p : const LedWhitePoints();
  }

  @override
  bool operator ==(Object other) =>
      other is LedWhitePoints &&
      other.wK == wK &&
      other.cwK == cwK &&
      other.wwK == wwK;

  @override
  int get hashCode => Object.hash(wK, cwK, wwK);

  @override
  String toString() => 'LedWhitePoints(W $wK K, CW $cwK K, WW $wwK K)';
}
