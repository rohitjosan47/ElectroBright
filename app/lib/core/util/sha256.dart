import 'dart:typed_data';

/// SHA-256 (FIPS 180-4), incremental. The firmware twin hashes a wireless
/// update as it arrives, like the light (firmware ota/Sha256.cpp).
final class Sha256 {
  Sha256() {
    reset();
  }

  static const int digestSize = 32;

  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final Uint32List _h = Uint32List(8);
  final Uint8List _buf = Uint8List(64);
  final Uint32List _w = Uint32List(64);
  int _used = 0;
  int _bytes = 0;

  /// SHA-256 of [data] in one call.
  static Uint8List of(List<int> data) => (Sha256()..update(data)).digest();

  void reset() {
    _h.setAll(0, const <int>[
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]);
    _used = 0;
    _bytes = 0;
  }

  /// A copy with the same running state (resume points).
  Sha256 copy() {
    final Sha256 c = Sha256();
    c._h.setAll(0, _h);
    c._buf.setAll(0, _buf);
    c._used = _used;
    c._bytes = _bytes;
    return c;
  }

  void update(List<int> data) {
    _bytes += data.length;
    for (final int b in data) {
      _buf[_used++] = b;
      if (_used == 64) {
        _block();
        _used = 0;
      }
    }
  }

  /// The digest so far; the running state is left untouched.
  Uint8List digest() {
    final Sha256 s = copy();
    final int bits = s._bytes * 8;
    s.update(const <int>[0x80]);
    while (s._used != 56) {
      s.update(const <int>[0]);
    }
    s.update(<int>[for (int i = 7; i >= 0; i--) (bits >> (8 * i)) & 0xFF]);
    final Uint8List out = Uint8List(digestSize);
    for (int i = 0; i < 8; i++) {
      out[4 * i] = s._h[i] >> 24;
      out[4 * i + 1] = s._h[i] >> 16;
      out[4 * i + 2] = s._h[i] >> 8;
      out[4 * i + 3] = s._h[i];
    }
    return out;
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  void _block() {
    final Uint32List w = _w;
    for (int i = 0; i < 16; i++) {
      w[i] =
          (_buf[4 * i] << 24) |
          (_buf[4 * i + 1] << 16) |
          (_buf[4 * i + 2] << 8) |
          _buf[4 * i + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    int a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    int e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ (~e & 0xFFFFFFFF & g);
      final int t1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }
}
