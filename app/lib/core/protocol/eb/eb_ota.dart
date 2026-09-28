/// Wireless update contract (firmware ota/OtaProtocol.h, docs/protocol.md §10):
/// a GATT service of its own, a control characteristic (write with response +
/// notify) and a data characteristic (write without response). Every number
/// is little-endian. `test/cross_repo/firmware_config_sync_test.dart` checks
/// these values against the firmware.
abstract final class EbOta {
  static const String serviceUuid = 'e1b70001-7a3c-4f4b-9e2d-5c8a1b0e0f01';
  static const String controlUuid = 'e1b70002-7a3c-4f4b-9e2d-5c8a1b0e0f01';
  static const String dataUuid = 'e1b70003-7a3c-4f4b-9e2d-5c8a1b0e0f01';

  // Requests (control).
  static const int begin =
      0x01; // size:u32 sha256:32 major:u16 minor:u16 patch:u16 flags:u8
  static const int end = 0x02;
  static const int abort = 0x03;
  static const int status = 0x04;
  static const int beginLength = 44;
  static const int flagReinstall = 0x01;

  // Replies (control notifications).
  static const int beginOk = 0x81; // start:u32 window:u16
  static const int ack = 0x82; // next:u32
  static const int endOk = 0x83;
  static const int aborted = 0x84;
  static const int state = 0x85; // state:u8 next:u32 size:u32
  static const int error = 0xE0; // code:u8 next:u32

  // STATE.
  static const int stateIdle = 0;
  static const int stateReceiving = 1;
  static const int stateRestarting = 2;

  /// DATA: offset:u32, then the payload.
  static const int dataHeader = 4;

  /// An ACK comes at least every this many bytes; the app keeps at most one
  /// unacknowledged window in flight.
  static const int window = 8192;

  /// No DATA for this long stops a transfer (it can be resumed in the same boot).
  static const int timeoutMs = 15000;
}

/// ERROR codes of the update control characteristic.
enum EbOtaError {
  badSize(1),
  hashMismatch(2),
  notElectroBright(3),
  downgrade(4),
  sameVersion(5),
  flashError(6),
  busy(7),
  badRequest(8),
  incomplete(9),
  timeout(10);

  const EbOtaError(this.code);
  final int code;

  static EbOtaError? fromCode(int code) {
    for (final EbOtaError e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}
