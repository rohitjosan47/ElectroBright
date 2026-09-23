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
};

class IControllerEnv {
 public:
  virtual void sendLine(const char* line) = 0;
  virtual void publish(const RenderParams& params) = 0;
  virtual void playSound(SoundId id) = 0;
  virtual void systemDiag(SystemDiag& out) = 0;

 protected:
  ~IControllerEnv() = default;
};

class ControllerCore {
 public:
  ControllerCore(IControllerEnv& env, StateStore& store, Stats& stats);

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

  const Scene& scene() const { return scene_; }
  const Settings& settings() const { return settings_; }
  bool sleeping() const { return sleeping_; }
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
  void sendStatus(uint32_t nowMs);
  void sendDiag();
  void checkStorage(bool ok);

  IControllerEnv& env_;
  StateStore& store_;
  Stats& stats_;

  Scene scene_{};
  Settings settings_{};
  bool sleeping_ = false;
  uint16_t fadeMs_ = 0;
  bool timerActive_ = false;
  uint32_t timerDeadlineMs_ = 0;
  bool haveSeq_ = false;
  uint8_t expectedSeq_ = 0;
  bool storageErrorReported_ = false;
  char buf_[384] = {};  // large enough for the DIAG line
};
