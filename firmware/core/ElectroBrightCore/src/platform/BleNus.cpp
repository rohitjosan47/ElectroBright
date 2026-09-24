#include "BleNus.h"

#include <NimBLEDevice.h>

#include <atomic>

#include "../config/Config.h"
#include "../protocol/BinaryFrame.h"

namespace {

BleSinks g_sinks{};
const FixtureProfile* g_fixture = nullptr;
NimBLECharacteristic* g_tx = nullptr;
std::atomic<bool> g_connected{false};
std::atomic<uint16_t> g_connHandle{BLE_HS_CONN_HANDLE_NONE};
std::atomic<uint16_t> g_mtu{23};

void postEvent(BleEvent e) {
  const uint8_t v = static_cast<uint8_t>(e);
  xQueueSend(g_sinks.events, &v, 0);
  xTaskNotifyGive(g_sinks.controlTask);
}

class ServerCallbacks final : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override {
    g_connHandle = info.getConnHandle();
    g_mtu = 23;
    g_connected = true;
    // 15–30 ms interval, no latency, 4 s supervision timeout: responsive
    // streaming without starving the phone's radio.
    server->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);
    postEvent(BleEvent::Connected);
  }

  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    g_connected = false;
    g_connHandle = BLE_HS_CONN_HANDLE_NONE;
    postEvent(BleEvent::Disconnected);  // advertising restarts automatically
  }

  void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override { g_mtu = mtu; }
};

class RxCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo&) override {
    const NimBLEAttValue value = chr->getValue();
    const uint8_t* data = value.data();
    const size_t len = value.size();
    if (len == 0) return;

    const ChannelLayout& layout = *g_fixture->layout;
    if (binframe::isCandidate(data, len, layout)) {
      ColorFrame frame{};
      if (binframe::decode(data, len, layout, g_fixture->legacyFrames, frame)) {
        xQueueOverwrite(g_sinks.colorMailbox, &frame);  // only the newest colour matters
        Stats::inc(g_sinks.stats->binaryOk);
      } else {
        Stats::inc(g_sinks.stats->binaryBad);
      }
    } else if (xStreamBufferSpacesAvailable(g_sinks.rxText) >= len) {
      // All-or-nothing, so a partially stored write can never splice two
      // commands together.
      xStreamBufferSend(g_sinks.rxText, data, len, 0);
    } else {
      Stats::inc(g_sinks.stats->rxStreamDrops);
    }
    xTaskNotifyGive(g_sinks.controlTask);
  }
};

ServerCallbacks g_serverCallbacks;
RxCallbacks g_rxCallbacks;

}  // namespace

namespace ble {

bool begin(const BleSinks& sinks, const FixtureProfile& fixture) {
  g_sinks = sinks;
  g_fixture = &fixture;

  NimBLEDevice::init(fixture.deviceName);
  NimBLEDevice::setPower(9);  // dBm
  NimBLEDevice::setMTU(cfg::kPreferredMtu);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(&g_serverCallbacks, false);
  server->advertiseOnDisconnect(true);

  NimBLEService* service = server->createService(cfg::kServiceUuid);
  g_tx = service->createCharacteristic(cfg::kTxCharUuid, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* rx =
      service->createCharacteristic(cfg::kRxCharUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rx->setCallbacks(&g_rxCallbacks);
  // NimBLE 2.x starts services together with the server (on advertising start).

  // The 128-bit service UUID and the name (up to 29 chars) do not both fit in
  // one 31-byte advertisement: UUID in the advertisement, name in the scan response.
  NimBLEAdvertisementData advData;
  advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  advData.addServiceUUID(NimBLEUUID(cfg::kServiceUuid));
  NimBLEAdvertisementData scanData;
  scanData.setName(fixture.deviceName);

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->enableScanResponse(true);  // must precede the setters (it clears the "data set" flag)
  adv->setAdvertisementData(advData);
  adv->setScanResponseData(scanData);
  adv->setMinInterval(160);  // 100 ms (units of 0.625 ms)
  adv->setMaxInterval(240);  // 150 ms
  return adv->start();
}

bool connected() { return g_connected.load(); }

size_t maxPayload() {
  const uint16_t mtu = g_mtu.load();
  return mtu > 3 ? static_cast<size_t>(mtu - 3) : 20;
}

bool notify(const uint8_t* data, size_t len) {
  if (!g_connected.load() || g_tx == nullptr) return false;
  return g_tx->notify(data, len, g_connHandle.load());
}

}  // namespace ble
