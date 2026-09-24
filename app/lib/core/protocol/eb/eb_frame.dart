import 'dart:typed_data';

import '../../model/channel_color.dart';

/// Binary colour fast path (firmware/core/ElectroBrightCore/src/protocol/BinaryFrame.h):
/// `[0xAA, seq, c1..cn, Br, seq^c1^..^cn^Br^salt]`, one value per channel of
/// the light's layout (n + 4 bytes; salt 0x55 for 4-channel layouts, 0x55^n
/// otherwise, so a frame for one fixture never passes another's checksum).
/// The firmware sends no reply; the frame sets colour and master brightness
/// but never wakes a sleeping light. Each frame must be its own BLE write.
abstract final class EbFrame {
  static const int magic = 0xAA;

  static Uint8List encode(int seq, ChannelColor color, int brightness) {
    assert(brightness >= 0 && brightness <= 255, 'brightness $brightness');
    final int s = seq & 0xFF;
    final int n = color.layout.n;
    final Uint8List out = Uint8List(color.layout.frameLength);
    out[0] = magic;
    out[1] = s;
    int sum = color.layout.salt ^ s ^ brightness;
    for (int i = 0; i < n; i++) {
      out[2 + i] = color[i];
      sum ^= color[i];
    }
    out[2 + n] = brightness;
    out[3 + n] = sum & 0xFF;
    return out;
  }
}
