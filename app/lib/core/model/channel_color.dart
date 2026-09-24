import 'package:meta/meta.dart';

import 'channel_layout.dart';

/// A colour exactly as the ElectroBright protocol carries it for one layout:
/// one perceptual (gamma-encoded) 0..255 value per channel, in wire order.
///
/// Two colours are equal only when their layouts match too, so values of
/// different fixtures can never be confused.
@immutable
final class ChannelColor {
  /// Throws [ArgumentError] unless [values] has one 0..255 value per channel.
  ChannelColor(this.layout, List<int> values) : _packed = _pack(layout, values);

  const ChannelColor._(this.layout, this._packed);

  /// Builds a colour from role values; roles the layout lacks must be 0.
  factory ChannelColor.roles(
    ChannelLayout layout, {
    int r = 0,
    int g = 0,
    int b = 0,
    int w = 0,
    int cw = 0,
    int ww = 0,
  }) {
    final Map<ChannelRole, int> byRole = <ChannelRole, int>{
      ChannelRole.r: r,
      ChannelRole.g: g,
      ChannelRole.b: b,
      ChannelRole.w: w,
      ChannelRole.cw: cw,
      ChannelRole.ww: ww,
    };
    for (final MapEntry<ChannelRole, int> e in byRole.entries) {
      if (!layout.has(e.key) && e.value != 0) {
        throw ArgumentError('${layout.wire} has no ${e.key.name} channel');
      }
    }
    return ChannelColor(layout, <int>[
      for (final ChannelRole role in layout.roles) byRole[role]!,
    ]);
  }

  /// RGBW convenience (the original fixture; tests and migrations).
  factory ChannelColor.rgbw(int r, int g, int b, int w) =>
      ChannelColor(ChannelLayout.rgbw, <int>[r, g, b, w]);

  static ChannelColor black(ChannelLayout layout) => ChannelColor._(layout, 0);

  /// Full on every channel.
  static ChannelColor full(ChannelLayout layout) =>
      ChannelColor(layout, List<int>.filled(layout.n, 255));

  final ChannelLayout layout;

  // Channel i in bits 8i..8i+7 (at most 5 channels = 40 bits).
  final int _packed;

  static int _pack(ChannelLayout layout, List<int> values) {
    if (values.length != layout.n) {
      throw ArgumentError(
        '${layout.wire} needs ${layout.n} values, got ${values.length}',
      );
    }
    int packed = 0;
    for (int i = 0; i < values.length; i++) {
      final int v = values[i];
      if (v < 0 || v > 255) throw ArgumentError('channel $i out of range: $v');
      packed |= v << (8 * i);
    }
    return packed;
  }

  int get length => layout.n;

  int operator [](int i) {
    RangeError.checkValidIndex(i, this, 'index', layout.n);
    return (_packed >> (8 * i)) & 0xFF;
  }

  List<int> get values => <int>[for (int i = 0; i < layout.n; i++) this[i]];

  /// Value of [role], 0 when the layout has no such channel.
  int role(ChannelRole role) {
    final int i = layout.indexOf(role);
    return i < 0 ? 0 : this[i];
  }

  ChannelColor withValue(int index, int value) =>
      ChannelColor(layout, values..[index] = value);

  ChannelColor withRole(ChannelRole role, int value) {
    final int i = layout.indexOf(role);
    if (i < 0) throw ArgumentError('${layout.wire} has no ${role.name}');
    return withValue(i, value);
  }

  int get maxChannel {
    int m = 0;
    for (int i = 0; i < layout.n; i++) {
      if (this[i] > m) m = this[i];
    }
    return m;
  }

  bool get isBlack => _packed == 0;

  List<int> toJson() => values;

  /// Strict: null unless [json] is a list of exactly n ints in 0..255.
  static ChannelColor? fromJson(ChannelLayout layout, Object? json) {
    if (json is! List<Object?> || json.length != layout.n) return null;
    final List<int> v = <int>[];
    for (final Object? e in json) {
      if (e is! int || e < 0 || e > 255) return null;
      v.add(e);
    }
    return ChannelColor(layout, v);
  }

  @override
  bool operator ==(Object other) =>
      other is ChannelColor &&
      other.layout == layout &&
      other._packed == _packed;

  @override
  int get hashCode => Object.hash(layout, _packed);

  @override
  String toString() => '${layout.wire}(${values.join(',')})';
}
