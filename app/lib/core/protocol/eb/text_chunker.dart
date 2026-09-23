import 'dart:typed_data';

import 'eb_constants.dart';

/// Splits one command line into BLE writes of at most `max(20, mtu - 3)`
/// bytes. The firmware's line assembler joins fragments until '\n', so a long
/// command survives an MTU that was never exchanged.
List<Uint8List> chunkCommand(String line, int mtu) {
  assert(!line.contains('\n') && !line.contains('\r'), 'one line only');
  final List<int> bytes = <int>[...line.codeUnits, 0x0A];
  for (final int b in bytes) {
    if (b > 0x7E || (b < 0x20 && b != 0x0A)) {
      throw ArgumentError.value(line, 'line', 'must be printable ASCII');
    }
  }
  final int size = mtu - 3 > Eb.minPayload ? mtu - 3 : Eb.minPayload;
  final List<Uint8List> chunks = <Uint8List>[];
  for (int i = 0; i < bytes.length; i += size) {
    final int end = i + size < bytes.length ? i + size : bytes.length;
    chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
  }
  return chunks;
}

/// Written after a command timed out: the control byte makes the firmware
/// discard any half-received line (no reply), the '\n' closes it. Prevents a
/// truncated command (e.g. "TIMER:8" from "TIMER:86400") from executing when
/// the next command's terminator arrives.
final Uint8List lineResetWrite = Uint8List.fromList(const <int>[0x15, 0x0A]);
