#pragma once
// Wireless update protocol (docs/protocol.md §10): a GATT service of its own
// with a control characteristic (write with response + notify) and a data
// characteristic (write without response). Every number is little-endian.
//
//   control  BEGIN   01 size:u32 sha256:32 major:u16 minor:u16 patch:u16 flags:u8   (44 bytes)
//            END     02
//            ABORT   03
//            STATUS  04
//   data     DATA    offset:u32 payload…
//   notify   BEGIN_OK 81 start:u32 window:u16      where the app starts; the ack window
//            ACK      82 next:u32                  next offset the light expects
//            END_OK   83                           verified; the light restarts now
//            ABORTED  84
//            STATE    85 state:u8 next:u32 size:u32
//            ERROR    E0 code:u8 next:u32

#include <stddef.h>
#include <stdint.h>

namespace ota {

constexpr const char* kServiceUuid = "E1B70001-7A3C-4F4B-9E2D-5C8A1B0E0F01";
constexpr const char* kControlUuid = "E1B70002-7A3C-4F4B-9E2D-5C8A1B0E0F01";  // write + notify
constexpr const char* kDataUuid = "E1B70003-7A3C-4F4B-9E2D-5C8A1B0E0F01";     // write without response

// Requests.
constexpr uint8_t kBegin = 0x01;
constexpr uint8_t kEnd = 0x02;
constexpr uint8_t kAbort = 0x03;
constexpr uint8_t kStatus = 0x04;
constexpr size_t kBeginLength = 44;
constexpr uint8_t kFlagReinstall = 0x01;  // BEGIN flags: allow the running version

// Replies.
constexpr uint8_t kBeginOk = 0x81;
constexpr uint8_t kAck = 0x82;
constexpr uint8_t kEndOk = 0x83;
constexpr uint8_t kAborted = 0x84;
constexpr uint8_t kState = 0x85;
constexpr uint8_t kError = 0xE0;

// STATE reply.
constexpr uint8_t kStateIdle = 0;
constexpr uint8_t kStateReceiving = 1;
constexpr uint8_t kStateRestarting = 2;

// ERROR codes. Never silent: every refused request gets one.
enum class Error : uint8_t {
  BadSize = 1,           // BEGIN size is 0 or larger than the spare slot; a chunk past the end
  HashMismatch = 2,      // END: the received bytes do not have the announced SHA-256
  NotElectroBright = 3,  // END: not a valid app image, or no ElectroBright universal identity of that version
  Downgrade = 4,         // BEGIN: older than the running firmware
  SameVersion = 5,       // BEGIN: the running version without the reinstall flag
  FlashError = 6,        // the spare slot could not be written or selected
  Busy = 7,              // another transfer, a restart pending, or the new firmware is not confirmed yet
  BadRequest = 8,        // malformed request, or END / DATA with no transfer
  Incomplete = 9,        // END before every byte arrived (next: where to continue)
  Timeout = 10,          // no data for kTimeoutMs: the transfer was stopped (unsolicited)
};

constexpr size_t kDataHeader = 4;      // DATA offset
constexpr uint32_t kWindow = 8192;     // an ACK at least every this many bytes
constexpr uint32_t kTimeoutMs = 15000; // no DATA for this long ends a transfer

}  // namespace ota
