#pragma once
// The single owner of device state (actor model). Only the control task calls
// into this class, so no field here is ever touched concurrently.
//
// Inputs:  text lines, binary colour frames, connection events, time ticks.
// Outputs: reply lines, RenderParams snapshots, sounds (through IControllerEnv).
//
// Portable: no Arduino / ESP-IDF dependencies, fully exercised by host tests.

#include <stddef.h>
#include <stdint.h>

#include "../core/Stats.h"
#include "../fixture/FixtureProfile.h"
#include "../feedback/SoundSequencer.h"
#include "../protocol/BinaryFrame.h"
#include "../protocol/CommandParser.h"
#include "../render/RenderParams.h"
#include "../state/StateStore.h"

struct SystemDiag {
  uint32_t minFreeHeap = 0;
  uint32_t controlStackFree = 0;
  uint32_t renderStackFree = 0;
  uint32_t resetReason = 0;
  uint32_t uptimeSec = 0;
  uint32_t runningSlot = 0;    // OTA app slot the firmware runs from
  uint32_t rolledBack = 0;     // 1: a rollback has happened since the rolled-back slot was last written
  uint32_t pendingVerify = 0;  // 1: this firmware is new and has not confirmed itself yet
  uint32_t finishMs = 0;       // the last update's END-to-END_OK time (0: none recorded)
};

class IControllerEnv {
 public:
  virtual void sendLine(const char* line) = 0;
  virtual void publish(const RenderParams& params) = 0;
  virtual void playSound(SoundId id) = 0;
  virtual void systemDiag(SystemDiag& out) = 0;
  // Restarts the light once the replies queued so far have been sent (SET_TYPE).
  // The platform calls flushStorage() right before it restarts.
  virtual void restart() = 0;

 protected:
  ~IControllerEnv() = default;
};

class ControllerCore {
 public:
  // `system`: the store of the fixture type (fixture/FixtureSelect.h).
  // `fixture`: the active profile; profiles::kNone runs setup-needed mode.
  ControllerCore(IControllerEnv& env, StateStore& store, IKeyValueStore& system, Stats& stats,
                 const FixtureProfile& fixture);

  void begin(uint32_t nowMs);
  void onConnect(uint32_t nowMs);
  void onDisconnect(uint32_t nowMs);
  void onColorFrame(const ColorFrame& frame, uint32_t nowMs);
  // Executes a batch of lines in order; consecutive same-kind colour /
  // brightness / speed / frequency lines collapse to the last one.
  void processLines(const char* const* lines, size_t count, uint32_t nowMs);
  void handleLine(const char* line, uint32_t nowMs) { processLines(&line, 1, nowMs); }
  // Timer expiry and persistence; call at least every ~100 ms.
  void tick(uint32_t nowMs);
  // A wireless update is receiving (or verified and about to restart): normal
  // commands are refused as busy, queries still answer, colour frames are
  // ignored, and effects, identify and probes stop.
  void setOtaBusy(bool busy);
  // The running firmware is new and not confirmed yet (ota/SelfCheck.h):
  // SET_TYPE and FACTORY_RESET are refused as busy until it is.
  void setPendingVerify(bool pending) { pendingVerify_ = pending; }
  // CAPS OTA=: the spare slot an update installs to (selfcheck::updateSlotBytes; 0: none).
  void setUpdateSlotBytes(uint32_t bytes) { updateSlotBytes_ = bytes; }
  // Commits every held storage write now (before a planned restart).
  void flushStorage();

  const Scene& scene() const { return scene_; }
  const Settings& settings() const { return settings_; }
  const FixtureProfile& fixture() const { return fixture_; }
  bool sleeping() const { return sleeping_; }
  bool setupNeeded() const { return setup_; }
  bool otaBusy() const { return otaBusy_; }
  bool pendingVerify() const { return pendingVerify_; }
  bool restartPending() const { return restartPending_; }
  int probeOutput() const { return probe_ ? probe_ - 1 : -1; }
  bool timerActive() const { return timerActive_; }
  uint32_t timerRemainingSec(uint32_t nowMs) const;

 private:
  void execute(const Command& c, uint32_t nowMs);
  void reportError(const char* code);
  void sound(SoundId id);
  void publish();
  void sceneChanged(uint32_t nowMs);
  void wake();
  void sleep(uint16_t fadeMs);
  void endIdentify();
  void sendStatus(uint32_t nowMs);
  void sendDiag();
  void checkStorage(bool ok);
  void setType(FixtureType type);
  void endProbe();

  IControllerEnv& env_;
  StateStore& store_;
  IKeyValueStore& system_;
  Stats& stats_;
  const FixtureProfile& fixture_;

  Scene scene_{};
  Settings settings_{};
  bool sleeping_ = false;
  uint16_t fadeMs_ = 0;
  bool identifying_ = false;  // an IDENTIFY is published (see RenderParams::identifyId)
  uint16_t identifySeq_ = 0;  // id of the latest IDENTIFY; never reused back to back
  bool timerActive_ = false;
  uint32_t timerDeadlineMs_ = 0;
  bool haveSeq_ = false;
  uint8_t expectedSeq_ = 0;
  bool storageErrorReported_ = false;
  const bool setup_;             // setup-needed mode: no fixture type
  bool restartPending_ = false;  // SET_TYPE done: ignore everything until the restart
  bool otaBusy_ = false;
  bool pendingVerify_ = false;
  uint32_t updateSlotBytes_ = 0;
  uint8_t probe_ = 0;            // RenderParams::probe
  uint32_t probeDeadlineMs_ = 0;
  char buf_[448] = {};  // large enough for the DIAG line (26 fields of up to 10 digits: 423)
};
