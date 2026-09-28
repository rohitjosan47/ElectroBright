#include "BleNus.h"

#include <NimBLEDevice.h>

#include <string.h>

#include <atomic>

#include "../config/Config.h"
#include "../ota/OtaProtocol.h"
#include "../protocol/BinaryFrame.h"

namespace {

// Connection intervals (1.25 ms units).
constexpr uint16_t kNormalMin = 12;  // 15 ms
constexpr uint16_t kNormalMax = 24;  // 30 ms
constexpr uint16_t kFastMin = 6;     // 7.5 ms (iOS grants 15 ms)
constexpr uint16_t kFastMax = 12;

BleSinks g_sinks{};
const FixtureProfile* g_fixture = nullptr;
NimBLECharacteristic* g_tx = nullptr;
NimBLECharacteristic* g_otaControl = nullptr;
NimBLEServer* g_server = nullptr;
// Set in begin() (setup task), read by the control task's first-boot check.
std::atomic<NimBLEService*> g_commandService{nullptr};
std::atomic<NimBLEService*> g_updateService{nullptr};
std::atomic<bool> g_commandAdvertised{false};  // the advertisement carries the command service UUID and started
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
    server->updateConnParams(info.getConnHandle(), kNormalMin, kNormalMax, 0, 400);
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

// Update control: small requests, handed over whole.
class OtaControlCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo&) override {
    const NimBLEAttValue value = chr->getValue();
    OtaControlMsg msg{};
    msg.len = static_cast<uint8_t>(value.size() < sizeof(msg.data) ? value.size() : sizeof(msg.data));
    memcpy(msg.data, value.data(), msg.len);
    if (value.size() > sizeof(msg.data)) msg.len = 0;  // malformed: the receiver says so
    xQueueSend(g_sinks.otaControl, &msg, 0);
    xTaskNotifyGive(g_sinks.controlTask);
  }
};

// Update data: copied into a message buffer (one write per message); the
// control task writes it to flash. A write that does not fit is dropped and
// the receiver's ACK brings the app back to it.
class OtaDataCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo&) override {
    const NimBLEAttValue value = chr->getValue();
    if (value.size() > 0 && value.size() <= cfg::kOtaMaxWrite) {
      xMessageBufferSend(g_sinks.otaData, value.data(), value.size(), 0);
    }
    xTaskNotifyGive(g_sinks.controlTask);
  }
};

ServerCallbacks g_serverCallbacks;
RxCallbacks g_rxCallbacks;
OtaControlCallbacks g_otaControlCallbacks;
OtaDataCallbacks g_otaDataCallbacks;

}  // namespace

namespace ble {

bool begin(const BleSinks& sinks, const FixtureProfile& fixture) {
  g_sinks = sinks;
  g_fixture = &fixture;

  NimBLEDevice::init(fixture.deviceName);
  NimBLEDevice::setPower(9);  // dBm
  NimBLEDevice::setMTU(cfg::kPreferredMtu);

  NimBLEServer* server = NimBLEDevice::createServer();
  g_server = server;
  server->setCallbacks(&g_serverCallbacks, false);
  server->advertiseOnDisconnect(true);

  NimBLEService* service = server->createService(cfg::kServiceUuid);
  g_commandService = service;
  g_tx = service->createCharacteristic(cfg::kTxCharUuid, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* rx =
      service->createCharacteristic(cfg::kRxCharUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rx->setCallbacks(&g_rxCallbacks);

  NimBLEService* update = server->createService(ota::kServiceUuid);
  g_updateService = update;
  g_otaControl = update->createCharacteristic(ota::kControlUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);
  g_otaControl->setCallbacks(&g_otaControlCallbacks);
  NimBLECharacteristic* data = update->createCharacteristic(ota::kDataUuid, NIMBLE_PROPERTY::WRITE_NR);
  data->setCallbacks(&g_otaDataCallbacks);
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
  const bool started = adv->start();
  g_commandAdvertised = started;
  return started;
}

bool connected() { return g_connected.load(); }

bool advertising() { return NimBLEDevice::getAdvertising()->isAdvertising(); }

bool commandServiceUp() {
  const NimBLEService* s = g_commandService.load();
  return s && s->isStarted() && g_commandAdvertised.load();
}

bool updateServiceUp() {
  const NimBLEService* s = g_updateService.load();
  return s && s->isStarted();
}

size_t maxPayload() {
  const uint16_t mtu = g_mtu.load();
  return mtu > 3 ? static_cast<size_t>(mtu - 3) : 20;
}

bool notify(const uint8_t* data, size_t len) {
  if (!g_connected.load() || g_tx == nullptr) return false;
  return g_tx->notify(data, len, g_connHandle.load());
}

bool otaNotify(const uint8_t* data, size_t len) {
  if (!g_connected.load() || g_otaControl == nullptr) return false;
  return g_otaControl->notify(data, len, g_connHandle.load());
}

void setUpdateLink(bool fast) {
  const uint16_t h = g_connHandle.load();
  if (!g_connected.load() || g_server == nullptr) return;
  if (fast) {
    g_server->updateConnParams(h, kFastMin, kFastMax, 0, 400);
    g_server->updatePhy(h, BLE_GAP_LE_PHY_2M_MASK, BLE_GAP_LE_PHY_2M_MASK, 0);
  } else {
    g_server->updateConnParams(h, kNormalMin, kNormalMax, 0, 400);
    g_server->updatePhy(h, BLE_GAP_LE_PHY_1M_MASK, BLE_GAP_LE_PHY_1M_MASK, 0);
  }
}

}  // namespace ble
