/// Channel layouts of the ElectroBright fixture family: which LEDs a light
/// has, in wire order. Mirrors firmware ChannelLayout.h (layouts::k*), and the
/// fixture table of docs/protocol.md.
///
/// A layout fixes how many values (n) every colour has on the wire: COLOR,
/// POLICE_COLOR_A/B, the binary frame (n + 4 bytes, per-layout checksum salt)
/// and STATUS (3n + 11 fields).
library;

enum ChannelRole { r, g, b, w, cw, ww }

/// The white LEDs a layout has.
enum WhiteKind {
  /// No white LED (RGB).
  none,

  /// One white LED (RGBW, W).
  single,

  /// Cool + warm white LEDs (CCT, RGBCCT).
  tunable,
}

enum ChannelLayout {
  w('W', <ChannelRole>[ChannelRole.w]),
  cct('CCT', <ChannelRole>[ChannelRole.cw, ChannelRole.ww]),
  rgb('RGB', <ChannelRole>[ChannelRole.r, ChannelRole.g, ChannelRole.b]),
  rgbw('RGBW', <ChannelRole>[
    ChannelRole.r,
    ChannelRole.g,
    ChannelRole.b,
    ChannelRole.w,
  ]),
  rgbcct('RGBCCT', <ChannelRole>[
    ChannelRole.r,
    ChannelRole.g,
    ChannelRole.b,
    ChannelRole.cw,
    ChannelRole.ww,
  ]);

  const ChannelLayout(this.wire, this.roles);

  /// Name on the wire: CAPS `LAYOUT=` and the model-id segment.
  final String wire;

  /// LEDs in wire order.
  final List<ChannelRole> roles;

  int get n => roles.length;

  /// Binary colour frame `[AA, seq, c1..cn, Br, cs]`.
  int get frameLength => n + 4;

  /// Checksum salt of the binary frame (0x55 for 4-channel layouts).
  int get salt => n == 4 ? 0x55 : 0x55 ^ n;

  /// STATUS field count: colour, 11 scalars, police A, police B.
  int get statusFields => 3 * n + 11;

  bool get hasColour => roles.contains(ChannelRole.r);

  WhiteKind get white => roles.contains(ChannelRole.cw)
      ? WhiteKind.tunable
      : roles.contains(ChannelRole.w)
      ? WhiteKind.single
      : WhiteKind.none;

  /// `RGBW:` exists only on the RGBW light (colour LEDs + one W LED).
  bool get acceptsRgbwAlias => this == rgbw;

  int indexOf(ChannelRole role) => roles.indexOf(role);

  bool has(ChannelRole role) => roles.contains(role);

  static ChannelLayout? fromWire(String wire) {
    for (final ChannelLayout l in values) {
      if (l.wire == wire) return l;
    }
    return null;
  }

  /// The layout whose STATUS has [fields] fields (n is unique in the family).
  static ChannelLayout? fromStatusFieldCount(int fields) {
    for (final ChannelLayout l in values) {
      if (l.statusFields == fields) return l;
    }
    return null;
  }
}
