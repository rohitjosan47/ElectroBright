#include "SoundSequencer.h"

#include <stddef.h>

namespace {
// Pitches: C6 1047, E6 1319, G6 1568, A6 1760, C7 2093.
constexpr Note kBoot[] = {{1047, 40}, {1319, 40}, {1568, 40}, {2093, 60}};
constexpr Note kMode[] = {{2093, 20}, {0, 20}, {2093, 20}};
constexpr Note kSave[] = {{1319, 40}, {1568, 40}, {2093, 60}};
constexpr Note kLoad[] = {{2093, 40}, {1568, 40}, {1319, 60}};
constexpr Note kDelete[] = {{1568, 30}, {1319, 30}, {1047, 40}};
constexpr Note kError[] = {{150, 80}, {0, 40}, {150, 120}};
constexpr Note kTimerSet[] = {{1760, 30}, {1319, 40}};
constexpr Note kTimerCancel[] = {{1319, 30}, {1047, 40}};
constexpr Note kSleep[] = {{1568, 20}, {1047, 30}};
constexpr Note kWake[] = {{1047, 20}, {1568, 30}};
constexpr Note kSoundOn[] = {{1047, 30}, {1319, 30}, {1568, 30}};
constexpr Note kFactory[] = {{2093, 50}, {1568, 50}, {1319, 50}, {1047, 100}};
constexpr Note kConnect[] = {{1568, 25}};

template <size_t N>
const Note* pick(const Note (&arr)[N], uint8_t& count) {
  count = static_cast<uint8_t>(N);
  return arr;
}
}  // namespace

const Note* SoundSequencer::melody(SoundId id, uint8_t& count) {
  switch (id) {
    case SoundId::Boot: return pick(kBoot, count);
    case SoundId::ModeChange: return pick(kMode, count);
    case SoundId::Save: return pick(kSave, count);
    case SoundId::Load: return pick(kLoad, count);
    case SoundId::Delete: return pick(kDelete, count);
    case SoundId::Error: return pick(kError, count);
    case SoundId::TimerSet: return pick(kTimerSet, count);
    case SoundId::TimerCancel: return pick(kTimerCancel, count);
    case SoundId::Sleep: return pick(kSleep, count);
    case SoundId::Wake: return pick(kWake, count);
    case SoundId::SoundOn: return pick(kSoundOn, count);
    case SoundId::FactoryReset: return pick(kFactory, count);
    case SoundId::Connect: return pick(kConnect, count);
    case SoundId::Identify: return pick(kConnect, count);  // the same single short chirp
    default: count = 0; return nullptr;
  }
}

void SoundSequencer::tick(uint32_t nowMs, IToneOutput& out) {
  const uint8_t req = request_.exchange(0, std::memory_order_acq_rel);
  if (req != 0) {
    notes_ = melody(static_cast<SoundId>(req), count_);
    idx_ = 0;
    started_ = false;
    if (notes_ == nullptr) out.tone(0);
  }
  if (notes_ == nullptr) return;

  if (!started_) {
    out.tone(notes_[idx_].hz);
    stepStart_ = nowMs;
    started_ = true;
    return;
  }
  if (static_cast<uint32_t>(nowMs - stepStart_) >= notes_[idx_].ms) {
    ++idx_;
    if (idx_ >= count_) {
      notes_ = nullptr;
      out.tone(0);
      return;
    }
    out.tone(notes_[idx_].hz);
    stepStart_ = nowMs;
  }
}
