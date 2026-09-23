/// Rebuilds reply lines from notification payloads. The firmware packs
/// '\n'-terminated ASCII lines back to back and cuts them at MTU-3 bytes, so
/// notification boundaries are unrelated to line boundaries.
///
/// Defensive rules: lines longer than [maxLineLength] or containing bytes
/// outside printable ASCII are dropped whole (counted), never truncated.
final class LineReassembler {
  LineReassembler({this.maxLineLength = 512});

  final int maxLineLength;
  final StringBuffer _line = StringBuffer();
  int _length = 0;
  bool _bad = false;

  int overflows = 0;
  int rejected = 0;

  /// Feeds one notification; returns the lines it completed, in order.
  List<String> add(List<int> bytes) {
    final List<String> lines = <String>[];
    for (final int c in bytes) {
      if (c == 0x0A || c == 0x0D) {
        if (_bad) {
          // counted when the line went bad
        } else if (_length > 0) {
          lines.add(_line.toString());
        }
        reset();
        continue;
      }
      if (_bad) continue;
      if (c < 0x20 || c > 0x7E) {
        _bad = true;
        rejected++;
        continue;
      }
      if (_length >= maxLineLength) {
        _bad = true;
        overflows++;
        continue;
      }
      _line.writeCharCode(c);
      _length++;
    }
    return lines;
  }

  /// Drops any partial line (new link / after a gap).
  void reset() {
    _line.clear();
    _length = 0;
    _bad = false;
  }
}
