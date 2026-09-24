#pragma once
// Additive light-pulse pool (portable, no heap).
//
// A pulse is a single flash of light: linear attack -> hold -> exponential
// decay. Pulses can be scheduled in the future, so a whole lightning flash or
// weld ignition is pre-built as a list of pulses and then simply played back.
// Overlapping pulses add up, the way light from separate discharges or sparks
// adds physically.
//
// The pool keeps its own clock ("effect time"). Callers advance it by
// dt / k, where k is a live speed factor: changing a slider rescales every
// pulse in flight immediately, without restarting anything.
//
// Two ways to read the pool each frame:
//   advance()          the level at the end of the frame (point sample)
//   advanceAveraged()  the exact average light over the frame (box filter):
//                      a spike shorter than a frame still delivers its true
//                      energy, and every edge lands at its exact sub-frame
//                      time instead of snapping to the 5 ms frame grid.

#include <math.h>
#include <stdint.h>

struct Pulse {
  float startMs;   // effect time at which the attack begins
  float attackMs;  // 0 = instant rise
  float holdMs;    // time at peak
  float tauMs;     // exponential decay time constant
  float peak;      // peak level
};

class PulsePool {
 public:
  static constexpr int kCapacity = 48;
  static constexpr float kDeadLevel = 1e-4f;  // below this a decaying pulse is retired

  void clear() {
    count_ = 0;
    now_ = 0.0f;
  }

  // Schedules a pulse `delayMs` after the current effect time. Returns false
  // (pulse dropped) when the pool is full.
  bool addIn(float delayMs, float attackMs, float holdMs, float tauMs, float peak) {
    if (count_ >= kCapacity) return false;
    if (count_ == 0) now_ = 0.0f;  // re-base the clock whenever idle (keeps floats precise forever)
    pulses_[count_++] = Pulse{now_ + delayMs, attackMs, holdMs, tauMs > 0.1f ? tauMs : 0.1f, peak};
    return true;
  }

  // Advances effect time and returns the summed level of all live pulses.
  float advance(float dtMs) {
    now_ += dtMs;
    float sum = 0.0f;
    int kept = 0;
    for (int i = 0; i < count_; ++i) {
      const Pulse& p = pulses_[i];
      const float t = now_ - p.startMs;
      float v = 0.0f;
      bool alive = true;
      if (t < 0.0f) {
        v = 0.0f;  // not started yet
      } else if (t < p.attackMs) {
        v = p.peak * (t / p.attackMs);
      } else if (t < p.attackMs + p.holdMs) {
        v = p.peak;
      } else {
        v = p.peak * expf(-(t - p.attackMs - p.holdMs) / p.tauMs);
        if (v < kDeadLevel) alive = false;
      }
      if (alive) {
        pulses_[kept++] = p;
        sum += v;
      }
    }
    count_ = kept;
    return sum;
  }

  // Advances effect time by dtMs and returns the mean summed level over that
  // interval (analytic integral of every pulse, divided by dtMs).
  float advanceAveraged(float dtMs) {
    if (dtMs <= 0.0f) return 0.0f;
    const float t0Abs = now_;
    now_ += dtMs;
    float energy = 0.0f;
    int kept = 0;
    for (int i = 0; i < count_; ++i) {
      const Pulse& p = pulses_[i];
      const float t0 = t0Abs - p.startMs;
      const float t1 = t0 + dtMs;
      energy += integral(p, t0, t1);
      // Retire once the decay has fallen below the dead level for the whole
      // next frame.
      const float decayStart = p.attackMs + p.holdMs;
      const bool dead = t1 > decayStart && p.peak * expf(-(t1 - decayStart) / p.tauMs) < kDeadLevel;
      if (!dead) pulses_[kept++] = p;
    }
    count_ = kept;
    return energy / dtMs;
  }

  float now() const { return now_; }

  bool idle() const { return count_ == 0; }
  int size() const { return count_; }

 private:
  // Integral of one pulse's level over [t0, t1] (times relative to its start).
  static float integral(const Pulse& p, float t0, float t1) {
    if (t1 <= 0.0f) return 0.0f;
    float sum = 0.0f;
    const float a = p.attackMs;
    const float holdEnd = p.attackMs + p.holdMs;
    if (a > 0.0f && t0 < a) {  // linear attack
      const float x1 = t0 > 0.0f ? t0 : 0.0f;
      const float x2 = t1 < a ? t1 : a;
      if (x2 > x1) sum += p.peak / (2.0f * a) * (x2 * x2 - x1 * x1);
    }
    if (t1 > a && t0 < holdEnd) {  // hold at peak
      const float x1 = t0 > a ? t0 : a;
      const float x2 = t1 < holdEnd ? t1 : holdEnd;
      if (x2 > x1) sum += p.peak * (x2 - x1);
    }
    if (t1 > holdEnd) {  // exponential decay
      const float x1 = (t0 > holdEnd ? t0 : holdEnd) - holdEnd;
      const float x2 = t1 - holdEnd;
      sum += p.peak * p.tauMs * (expf(-x1 / p.tauMs) - expf(-x2 / p.tauMs));
    }
    return sum;
  }

  Pulse pulses_[kCapacity] = {};
  int count_ = 0;
  float now_ = 0.0f;
};
