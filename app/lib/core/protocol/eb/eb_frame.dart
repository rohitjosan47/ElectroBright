import 'dart:typed_data';

import '../../model/rgbw.dart';

/// Binary colour fast path (firmware/ElectroBright/src/protocol/BinaryFrame.h):
/// `[0xAA, seq, R, G, B, W, Br, seq^R^G^B^W^Br^0x55]`. The firmware sends no
/// reply; the frame sets colour and master brightness but never wakes a
/// sleeping light. Each frame must be its own BLE write.
abstract final class EbFrame {
  static const int magic = 0xAA;
  static const int length = 8;

  static Uint8List encode(int seq, Rgbw color, int brightness) {
    assert(color.isValid, 'colour out of range: $color');
    assert(brightness >= 0 && brightness <= 255, 'brightness $brightness');
    final int s = seq & 0xFF;
    return Uint8List.fromList(<int>[
      magic,
      s,
      color.r,
      color.g,
      color.b,
      color.w,
      brightness,
      s ^ color.r ^ color.g ^ color.b ^ color.w ^ brightness ^ 0x55,
    ]);
  }
}
