#pragma once
// Nordic UART Service over NimBLE, plus the wireless-update service
// (ota/OtaProtocol.h: control + data characteristics).
//
// The NimBLE callbacks run on the BLE host task and do the bare minimum:
//  * binary 0xAA frames are validated and posted to a latest-wins mailbox;
//  * text bytes are appended to a stream buffer (whole write or nothing);
//  * connect / disconnect become events;
// then the control task is notified. No device state is touched here.

#include <freertos/FreeRTOS.h>
#include <freertos/message_buffer.h>
#include <freertos/queue.h>
#include <freertos/stream_buffer.h>
#include <freertos/task.h>
#include <stddef.h>
#include <stdint.h>

#include "../core/Stats.h"
#include "../fixture/FixtureProfile.h"

enum class BleEvent : uint8_t { Connected = 1, Disconnected = 2 };

// One write to the update control characteristic (requests are <= 44 bytes).
struct OtaControlMsg {
  uint8_t len;
  uint8_t data[48];
};

struct BleSinks {
  StreamBufferHandle_t rxText;   // text bytes -> control task
  QueueHandle_t colorMailbox;    // length-1 queue of ColorFrame (xQueueOverwrite)
  QueueHandle_t events;          // BleEvent
  TaskHandle_t controlTask;      // notified after every ingress
  Stats* stats;
  QueueHandle_t otaControl;          // OtaControlMsg
  MessageBufferHandle_t otaData;     // one DATA write per message (dropped whole when full)
};

namespace ble {

// `fixture` supplies the BLE name and the binary-frame layout; it must outlive the radio.
bool begin(const BleSinks& sinks, const FixtureProfile& fixture);
bool connected();
bool advertising();
// First-boot check (ota/SelfCheck.h): the command service is registered with
// the stack and in the advertisement; the update service is registered.
bool commandServiceUp();
bool updateServiceUp();
// Max bytes per notification for the current link (ATT MTU - 3).
size_t maxPayload();
// Sends one notification; false if the stack is out of buffers (retry later).
bool notify(const uint8_t* data, size_t len);
// The same on the update control characteristic.
bool otaNotify(const uint8_t* data, size_t len);
// During an update: the shortest connection interval and the 2M PHY the phone
// accepts; afterwards the normal parameters again.
void setUpdateLink(bool fast);

}  // namespace ble
