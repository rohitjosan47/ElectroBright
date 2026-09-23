#pragma once
// Effect interface. Each lighting mode is one Effect subclass with its own
// state (statically allocated inside RenderEngine, no heap).
//
// Contract:
//  * render() is called once per frame with the *current* slider values, so a
//    speed / frequency change takes effect on the very next frame. Effects keep
//    time in phase accumulators or store random factors (never absolute
//    deadlines), so a parameter change never restarts or jumps the animation.
//  * Output is linear light, 0..1 per channel, already including the effect's
//    own envelope. Master brightness and sleep fading are applied afterwards.

#include <stdint.h>

#include "../core/Rng.h"
#include "../core/Types.h"

struct EffectInput {
  LinColor base;       // smoothed base colour (linear)
  LinColor policeA;    // police custom colours (linear)
  LinColor policeB;
  uint8_t speed;       // 1..10
  uint8_t freq;        // 1..10
  uint8_t colorMode;   // mode-specific: 1 = auto palette, 0 = manual
  float dtMs;          // time since the previous frame of this effect
  Rng* rng;
};

class Effect {
 public:
  virtual void reset(Rng& rng) = 0;
  virtual LinColor render(const EffectInput& in) = 0;

 protected:
  ~Effect() = default;  // effects are never deleted through the base pointer
};
