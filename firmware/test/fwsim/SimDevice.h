#pragma once
// Host simulation of the ESP32-C3 platform glue around the REAL portable
// firmware core, so the Flutter app's protocol driver can be tested against
// the actual controller logic ("firmware in the loop").
//
// It mirrors, step for step (keep in sync when the platform layer changes):
//   src/platform/BleNus.cpp  RxCallbacks::onWrite, ServerCallbacks::onConnect /
//                            onDisconnect / onMTUChange, ble::notify, ble::maxPayload
//   src/platform/App.cpp     App::start() (fixture type), controlTask() steps 1-6
//                            and DeviceEnv
//
// Time is virtual: nothing happens between calls. A "pass" is one iteration of
// the control task loop; passBegin()/passEnd() split it at the point where
// text is drained, so tests can land a write in the middle of a pass exactly
// like a BLE callback racing the control task on the device.

#include <stddef.h>
#include <stdint.h>

#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "../Fakes.h"
#include "protocol/Egress.h"
#include "protocol/LineAssembler.h"

class SimDevice {
 public:
  // The universal firmware built with `buildDefault` as the type of a first
  // install (default: the RGBW light the app drives); FixtureType::None is a
  // build without a default (setup-needed mode until SET_TYPE).
  explicit SimDevice(FixtureType buildDefault = FixtureType::Rgbw);
  explicit SimDevice(const FixtureProfile& buildDefault) : SimDevice(buildDefault.type) {}
  // The controller's environment keeps a reference to this object.
  SimDevice(const SimDevice&) = delete;
  SimDevice& operator=(const SimDevice&) = delete;

  // App::start() step 4 (state load, first publish, boot sound).
  void boot();
  // Power cycle: RAM state is lost, flash (MockKv) survives, the link drops,
  // and the stored fixture type is read again.
  void reboot();
  // Times the light restarted itself (SET_TYPE).
  int restarts() const { return restarts_; }

  // --- Radio (BleNus.cpp) ------------------------------------------------------
  void connect();                 // ServerCallbacks::onConnect (MTU back to 23)
  void disconnect();              // ServerCallbacks::onDisconnect
  void setMtu(uint16_t mtu) { mtu_ = mtu; }  // ServerCallbacks::onMTUChange
  void setSubscribed(bool on) { subscribed_ = on; }
  void write(const uint8_t* data, size_t len);  // RxCallbacks::onWrite
  // Makes the next `count` notify() calls fail (stack out of buffers).
  void failNextNotifies(int count) { notifyFailures_ = count; }

  // --- Control task (App.cpp) ----------------------------------------------------
  void passBegin();  // steps 1-2: connection events, one mailbox frame
  void passEnd();    // steps 3-5: text, tick, replies
  void pass() {
    passBegin();
    passEnd();
  }
  // Idle wake-ups: the task runs at least every cfg::kControlWakeMs.
  void advance(uint32_t ms);

  // Notifications the phone received since the last call (each <= MTU-3 bytes).
  std::vector<std::vector<uint8_t>> takeNotifications();
  std::vector<SoundId> takeSounds();

  // --- Inspection -------------------------------------------------------------------
  const FixtureProfile& fixture() const { return rig_->fixture; }
  const ControllerCore& core() const { return rig_->core; }
  const StateStore& store() const { return rig_->store; }
  const Stats& stats() const { return rig_->stats; }
  const RenderParams& lastParams() const { return rig_->env.params; }
  MockKv& flash() { return kv_; }
  MockKv& systemFlash() { return system_; }
  uint32_t now() const { return now_; }
  bool connected() const { return connected_; }
  uint16_t mtu() const { return mtu_; }
  bool subscribed() const { return subscribed_; }
  size_t pendingText() const { return rxText_.size(); }
  bool mailboxFull() const { return mailboxFull_; }
  size_t pendingReplies() const { return egress_.pending(); }

 private:
  // App.cpp DeviceEnv: replies go to the egress buffer.
  class Env final : public IControllerEnv {
   public:
    explicit Env(SimDevice& dev) : dev_(dev) {}
    void sendLine(const char* line) override;
    void publish(const RenderParams& p) override { params = p; }
    void playSound(SoundId id) override { sounds.push_back(id); }
    void systemDiag(SystemDiag& d) override;
    void restart() override { restartRequested = true; }
    bool restartRequested = false;
    RenderParams params{};
    std::vector<SoundId> sounds;

   private:
    SimDevice& dev_;
  };

  // Everything that a reboot recreates (flash lives outside, in kv_ and
  // system_); App::start() picks the profile first.
  struct Rig {
    Rig(SimDevice& dev, MockKv& kv, MockKv& system, FixtureType buildDefault)
        : fixture(fxselect::select(system, buildDefault)),
          env(dev),
          store(kv, stats, fixture),
          core(env, store, system, stats, fixture) {}
    const FixtureProfile& fixture;
    Env env;
    Stats stats;
    StateStore store;
    ControllerCore core;
  };

  bool notify(const uint8_t* data, size_t len);  // ble::notify
  size_t maxPayload() const { return mtu_ > 3 ? static_cast<size_t>(mtu_ - 3) : 20; }

  void restartNow();

  const FixtureType buildDefault_;
  MockKv kv_;
  MockKv system_;
  int restarts_ = 0;
  std::unique_ptr<Rig> rig_;
  Egress egress_;
  LineAssembler assembler_;
  LineAssembler::Counters seen_{};
  std::deque<uint8_t> rxText_;  // FreeRTOS stream buffer, cfg::kRxStreamBytes
  ColorFrame mailbox_{};        // length-1 queue written with xQueueOverwrite
  bool mailboxFull_ = false;
  std::deque<uint8_t> events_;  // BleEvent queue
  bool connected_ = false;
  bool subscribed_ = false;
  uint16_t mtu_ = 23;
  int notifyFailures_ = 0;
  uint32_t now_ = 1000;
  std::vector<std::vector<uint8_t>> delivered_;
};
