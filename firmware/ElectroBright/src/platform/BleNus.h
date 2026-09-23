#pragma once
// Nordic UART Service over NimBLE.
//
// The NimBLE callbacks run on the BLE host task and do the bare minimum:
//  * binary 0xAA frames are validated and posted to a latest-wins mailbox;
//  * text bytes are appended to a stream buffer (whole write or nothing);
//  * connect / disconnect become events;
// then the control task is notified. No device state is touched here.

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/stream_buffer.h>
#include <freertos/task.h>
#include <stddef.h>
#include <stdint.h>

#include "../core/Stats.h"

enum class BleEvent : uint8_t { Connected = 1, Disconnected = 2 };

struct BleSinks {
  StreamBufferHandle_t rxText;   // text bytes -> control task
  QueueHandle_t colorMailbox;    // length-1 queue of ColorFrame (xQueueOverwrite)
  QueueHandle_t events;          // BleEvent
  TaskHandle_t controlTask;      // notified after every ingress
  Stats* stats;
};

namespace ble {

bool begin(const BleSinks& sinks);
bool connected();
// Max bytes per notification for the current link (ATT MTU - 3).
size_t maxPayload();
// Sends one notification; false if the stack is out of buffers (retry later).
bool notify(const uint8_t* data, size_t len);

}  // namespace ble
