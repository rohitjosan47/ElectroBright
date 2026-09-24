#pragma once
// Non-blocking buzzer melodies.
//
// play() is called by the control task, tick() by the render task (200 Hz).
// The hand-over is a single atomic byte, so there is no lock and no queue:
// a new sound simply pre-empts the one currently playing.

#include <atomic>
#include <stdint.h>

enum class SoundId : uint8_t {
  None = 0,
  Boot,
  ModeChange,
  Save,
  Load,
  Delete,
  Error,
  TimerSet,
  TimerCancel,
  Sleep,
  Wake,
  SoundOn,
  FactoryReset,
  Connect,
};

// Output port for the sequencer (implemented by the LEDC buzzer on device).
class IToneOutput {
 public:
  virtual void tone(uint16_t hz) = 0;  // 0 = silence
 protected:
  ~IToneOutput() = default;
};

struct Note {
  uint16_t hz;  // 0 = rest
  uint16_t ms;
};

class SoundSequencer {
 public:
  void play(SoundId id) { request_.store(static_cast<uint8_t>(id), std::memory_order_release); }
  void tick(uint32_t nowMs, IToneOutput& out);
  bool busy() const { return notes_ != nullptr; }

  static const Note* melody(SoundId id, uint8_t& count);

 private:
  std::atomic<uint8_t> request_{0};
  const Note* notes_ = nullptr;
  uint8_t count_ = 0;
  uint8_t idx_ = 0;
  uint32_t stepStart_ = 0;
  bool started_ = false;
};
