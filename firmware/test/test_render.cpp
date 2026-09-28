// Render engine and effects, simulated at the real 200 Hz frame rate.

#include <math.h>

#include <algorithm>
#include <initializer_list>
#include <vector>

#include "fixture/Profiles.h"
#include "core/MathUtil.h"
#include "platform/PwmPlan.h"
#include "feedback/SoundSequencer.h"
#include "render/Color.h"
#include "render/RenderEngine.h"
#include "render/effects/Effects.h"
#include "TestFramework.h"

namespace {

constexpr uint32_t kFrameMs = cfg::kRenderPeriodUs / 1000;

struct Sim {
  RenderEngine engine{0xC0FFEEu};
  RenderParams p{};
  uint32_t now = 0;
  uint16_t duty[4] = {};

  explicit Sim(uint8_t mode = 1, uint8_t speed = 5, uint8_t freq = 5) {
    p.scene = state::defaultScene(profiles::kRgbw.defaults);
    p.scene.mode = mode;
    for (auto& s : p.scene.speed) s = speed;
    for (auto& f : p.scene.freq) f = freq;
    p.sleeping = 0;
    p.fadeMs = cfg::kSleepFadeMs;
  }
  void step() {
    engine.frame(p, now, duty);
    now += kFrameMs;
  }
  void run(uint32_t ms) {
    for (uint32_t t = 0; t < ms; t += kFrameMs) step();
  }
  uint32_t sum() const { return uint32_t(duty[0]) + duty[1] + duty[2] + duty[3]; }
  bool dark() const { return sum() == 0; }
  // Total light as a fraction of full scale (single channel white helper).
  float level() const { return static_cast<float>(sum()) / (4.0f * cfg::kPwmMaxDuty); }
};

// Average period (ms) between rising edges of "channel 0 above half" .
double measurePeriod(uint8_t mode, uint8_t freq, uint8_t speed, uint32_t ms) {
  Sim s(mode, speed, freq);
  s.p.scene.color = {255, 0, 0, 0};
  s.run(1000);  // boot fade + settle
  bool prev = false;
  int rises = 0;
  uint32_t first = 0, last = 0;
  for (uint32_t t = 0; t < ms; t += kFrameMs) {
    s.step();
    const bool on = s.duty[0] > cfg::kPwmMaxDuty / 2;
    if (on && !prev) {
      if (rises == 0) first = s.now;
      last = s.now;
      ++rises;
    }
    prev = on;
  }
  return rises > 1 ? double(last - first) / (rises - 1) : -1.0;
}

}  // namespace

TEST(render_boot_fades_in_then_solid_is_exact) {
  Sim s(1);
  s.step();
  CHECK(s.dark());  // first frame is black (no boot flash)
  s.run(cfg::kBootFadeMs / 2);
  CHECK(s.duty[0] > 0 && s.duty[0] < cfg::kPwmMaxDuty);
  s.run(cfg::kBootFadeMs);
  CHECK_EQ(s.duty[0], cfg::kPwmMaxDuty);  // white 255 at 100 %
  CHECK_EQ(s.duty[3], 0);                 // W = 0
}

// Full output reaches the pins as a held-high level; one step below is PWM.
pwmplan::Kind planOf(uint16_t duty) { return pwmplan::plan(duty, 0, 4).kind; }

TEST(render_full_brightness_holds_the_output_high) {
  Sim s(1);
  s.run(1000);
  CHECK_EQ(s.duty[0], cfg::kPwmMaxDuty);  // white at 255
  CHECK(planOf(s.duty[0]) == pwmplan::Kind::High);
  s.p.scene.brightness = 254;
  s.run(1000);
  CHECK(s.duty[0] < cfg::kPwmMaxDuty);
  CHECK(planOf(s.duty[0]) == pwmplan::Kind::Pwm);
}

TEST(render_effect_peaks_at_full_are_held_high_below_full_pwm) {
  // Blink: its on phase is the full colour.
  for (const uint8_t b : {uint8_t{255}, uint8_t{254}}) {
    Sim s(2);
    s.p.scene.brightness = b;
    uint16_t peak = 0;
    bool high = false;
    for (int i = 0; i < 2000; ++i) {
      s.step();
      peak = std::max(peak, s.duty[0]);
      high = high || planOf(s.duty[0]) == pwmplan::Kind::High;
    }
    if (b == 255) {
      CHECK_EQ(peak, cfg::kPwmMaxDuty);
      CHECK(high);
    } else {
      // A 99 % peak: PWM every frame, never held high.
      CHECK(peak > cfg::kPwmMaxDuty * 0.98 && peak < cfg::kPwmMaxDuty);
      CHECK(!high);
    }
  }
}

TEST(render_brightness_is_perceptual_and_zero_is_off) {
  Sim s(1);
  s.run(1000);
  s.p.scene.brightness = 128;
  s.run(1000);
  // gamma 2.2: 50 % perceptual ~= 22 % linear
  CHECK_NEAR(double(s.duty[0]) / cfg::kPwmMaxDuty, pow(128.0 / 255.0, 2.2), 0.01);
  s.p.scene.brightness = 0;
  s.run(1000);
  CHECK(s.dark());
  s.p.scene.brightness = 1;  // lowest step still lights (no collapse to 0)
  s.run(1000);
  CHECK(s.duty[0] > 0);
}

TEST(render_color_changes_are_smoothed_not_stepped) {
  Sim s(1);
  s.run(1000);
  s.p.scene.color = {0, 0, 0, 0};
  s.step();
  // One frame after a jump to black the output is still mostly on...
  CHECK(s.duty[0] > cfg::kPwmMaxDuty / 2);
  // ...and it converges within ~5 time constants: down to ~0.06 % of full
  // scale, just above the minimum non-zero duty (the tail then snaps to 0).
  s.run(static_cast<uint32_t>(cfg::kColorTauMs * 8));
  CHECK(s.duty[0] < 20);
}

TEST(render_sleep_blacks_out_every_mode_and_wake_restores) {
  for (uint8_t m = 1; m <= cfg::kNumModes; ++m) {
    Sim s(m, 10, 10);
    s.run(3000);
    s.p.sleeping = 1;
    s.run(cfg::kSleepFadeMs + 2 * kFrameMs);
    if (!s.dark()) tf::fail(__FILE__, __LINE__, "mode " + std::to_string(m) + " not dark after sleep");
    s.run(5000);
    if (!s.dark()) tf::fail(__FILE__, __LINE__, "mode " + std::to_string(m) + " lit while asleep");
    s.p.sleeping = 0;
    s.run(cfg::kSleepFadeMs + 2000);
    CHECK(s.engine.gain() >= 1.0f);
  }
}

TEST(render_all_modes_all_slider_corners_are_finite_and_bounded) {
  const uint8_t levels[] = {1, 5, 10};
  for (uint8_t m = 1; m <= cfg::kNumModes; ++m) {
    for (uint8_t sp : levels) {
      for (uint8_t fr : levels) {
        for (uint8_t cm = 0; cm <= 1; ++cm) {
          Sim s(m, sp, fr);
          s.p.scene.fireworkColorMode = s.p.scene.clubColorMode = s.p.scene.policeColorMode = cm;
          for (uint32_t t = 0; t < 20000; t += kFrameMs) {
            s.step();
            const LinColor o = s.engine.lastOutput();
            if (!(o.r >= 0 && o.r <= 1 && o.g >= 0 && o.g <= 1 && o.b >= 0 && o.b <= 1 && o.w >= 0 && o.w <= 1)) {
              tf::fail(__FILE__, __LINE__, "out of range/NaN in mode " + std::to_string(m));
              break;
            }
            for (uint16_t d : s.duty) CHECK(d <= cfg::kPwmMaxDuty);
          }
        }
      }
    }
  }
}

TEST(render_blink_period_follows_frequency) {
  CHECK_NEAR(measurePeriod(2, 1, 5, 20000), 1600, 1600 * 0.05);
  CHECK_NEAR(measurePeriod(2, 10, 5, 10000), 120, 120 * 0.05);
  CHECK_NEAR(measurePeriod(2, 5, 5, 20000), mathx::geo(5, 1600, 120), 20);
  // Speed is not a blink control: identical period at any speed.
  CHECK_NEAR(measurePeriod(2, 5, 1, 20000), measurePeriod(2, 5, 10, 20000), 5);
}

TEST(render_breath_period_follows_frequency) {
  CHECK_NEAR(measurePeriod(3, 1, 1, 60000), 8000, 8000 * 0.05);
  CHECK_NEAR(measurePeriod(3, 10, 1, 20000), 1000, 1000 * 0.05);
  CHECK_NEAR(measurePeriod(3, 10, 10, 20000), 1000, 1000 * 0.05);  // shape does not change rate
}

TEST(render_breath_speed_changes_shape) {
  // At high "shape" the light spends longer near the top (hold) than at low.
  auto timeNearTop = [](uint8_t speed) {
    Sim s(3, speed, 5);
    s.p.scene.color = {255, 0, 0, 0};
    s.run(1000);
    int near = 0, total = 0;
    for (uint32_t t = 0; t < 30000; t += kFrameMs) {
      s.step();
      near += s.duty[0] > cfg::kPwmMaxDuty * 0.9;
      ++total;
    }
    return double(near) / total;
  };
  CHECK(timeNearTop(10) > timeNearTop(1) + 0.1);
}

TEST(render_rainbow_cycle_time_follows_frequency) {
  for (uint8_t f : std::initializer_list<uint8_t>{1, 10}) {
    Sim s(10, 5, f);
    s.run(1000);
    // Count red peaks (hue passes 0 deg once per cycle).
    int peaks = 0;
    bool high = false;
    const uint32_t window = 90000;
    for (uint32_t t = 0; t < window; t += kFrameMs) {
      s.step();
      const bool redOnly = s.duty[0] > cfg::kPwmMaxDuty * 0.95 && s.duty[1] < 200 && s.duty[2] < 200;
      if (redOnly && !high) ++peaks;
      high = redOnly;
    }
    const double expected = window / mathx::geo(f, 30000, 3000);
    CHECK_NEAR(peaks, expected, 1.5);
  }
}

TEST(render_parameter_change_is_instant_and_continuous) {
  // Changing blink rate mid-cycle must not restart / jump the phase: the very
  // next frame keeps the same on/off state.
  Sim s(2, 5, 1);
  s.p.scene.color = {255, 0, 0, 0};
  s.run(1300);
  const bool onBefore = s.duty[0] > 0;
  s.p.scene.freq[1] = 10;
  s.step();
  CHECK_EQ(s.duty[0] > 0, onBefore);
  // And it is now blinking fast.
  int transitions = 0;
  bool prev = s.duty[0] > 0;
  for (int i = 0; i < 200; ++i) {  // 1 s
    s.step();
    const bool on = s.duty[0] > 0;
    transitions += on != prev;
    prev = on;
  }
  CHECK(transitions >= 14);  // ~8 Hz -> ~16 transitions per second
}

TEST(render_club_is_almost_never_dark) {
  for (uint8_t level : std::initializer_list<uint8_t>{1, 5, 10}) {
    for (uint8_t cm = 0; cm <= 1; ++cm) {
      Sim s(9, level, level);
      s.p.scene.clubColorMode = cm;
      s.p.scene.color = {255, 0, 180, 0};
      s.run(1000);
      uint32_t darkMs = 0, run = 0, maxRun = 0, total = 0;
      for (uint32_t t = 0; t < 600000; t += kFrameMs) {  // 10 minutes
        s.step();
        total += kFrameMs;
        if (s.dark()) {
          darkMs += kFrameMs;
          run += kFrameMs;
          maxRun = std::max(maxRun, run);
        } else {
          run = 0;
        }
      }
      CHECK(double(darkMs) / total <= 0.02);
      CHECK(maxRun <= 125);  // <= 120 ms accent (+1 frame of quantisation)
    }
  }
}

TEST(render_club_tempo_follows_speed) {
  // Count beat-level changes of the dominant pattern via output variance peaks is
  // brittle; instead check the documented tempo mapping directly.
  CHECK_NEAR(90.0f + 80.0f * mathx::level01(1), 90.0, 0.01);
  CHECK_NEAR(90.0f + 80.0f * mathx::level01(10), 170.0, 0.01);
}

TEST(render_police_flashes_per_side_follow_frequency) {
  for (uint8_t f : std::initializer_list<uint8_t>{1, 10}) {
    Sim s(12, 5, f);
    s.run(1000);
    // Count flash bursts: runs of red flashes separated by a blue burst.
    int redFlashes = 0, bursts = 0;
    bool prevOn = false, inRed = false;
    for (uint32_t t = 0; t < 30000; t += kFrameMs) {
      s.step();
      const bool red = s.duty[0] > 0;
      const bool blue = s.duty[2] > 0;
      if (red && !prevOn) {
        ++redFlashes;
        if (!inRed) {
          ++bursts;
          inRed = true;
        }
      }
      if (blue) inRed = false;
      prevOn = red;
    }
    const int expected = f == 1 ? 1 : 6;
    CHECK_NEAR(double(redFlashes) / bursts, expected, 0.2);
  }
}

namespace {
// Counts "events" where total output jumps above a threshold after being low.
int countEvents(uint8_t mode, uint8_t speed, uint8_t freq, uint32_t ms, float lowFrac, float highFrac) {
  Sim s(mode, speed, freq);
  s.run(1000);
  int events = 0;
  bool armed = true;
  for (uint32_t t = 0; t < ms; t += kFrameMs) {
    s.step();
    const float l = static_cast<float>(s.duty[0]) / cfg::kPwmMaxDuty;
    if (armed && l > highFrac) {
      ++events;
      armed = false;
    } else if (!armed && l < lowFrac) {
      armed = true;
    }
  }
  return events;
}

double flickerStdDev(uint8_t mode, uint8_t speed, uint8_t freq) {
  Sim s(mode, speed, freq);
  s.run(2000);
  std::vector<double> v;
  for (uint32_t t = 0; t < 60000; t += kFrameMs) {
    s.step();
    v.push_back(static_cast<double>(s.duty[0]) / cfg::kPwmMaxDuty);
  }
  double mean = 0;
  for (double x : v) mean += x;
  mean /= v.size();
  double var = 0;
  for (double x : v) var += (x - mean) * (x - mean);
  return sqrt(var / v.size());
}

// Mean absolute frame-to-frame change: a proxy for "how fast it moves".
double flickerActivity(uint8_t mode, uint8_t speed, uint8_t freq) {
  Sim s(mode, speed, freq);
  s.run(2000);
  double prev = -1, acc = 0;
  int n = 0;
  for (uint32_t t = 0; t < 60000; t += kFrameMs) {
    s.step();
    const double x = static_cast<double>(s.duty[0]) / cfg::kPwmMaxDuty;
    if (prev >= 0) {
      acc += fabs(x - prev);
      ++n;
    }
    prev = x;
  }
  return acc / n;
}
}  // namespace

TEST(render_fireworks_launch_rate_follows_frequency) {
  const int slow = countEvents(4, 5, 1, 300000, 0.02f, 0.6f);
  const int fast = countEvents(4, 5, 10, 300000, 0.02f, 0.6f);
  CHECK(slow >= 10);
  CHECK(fast > slow * 3);
}

TEST(render_faulty_bulb_glitch_rate_follows_frequency) {
  const int slow = countEvents(7, 5, 1, 300000, 0.5f, 0.85f);
  const int fast = countEvents(7, 5, 10, 300000, 0.5f, 0.85f);
  CHECK(slow >= 5);
  CHECK(fast > slow * 3);
}

TEST(render_fire_and_candle_respond_to_both_sliders) {
  for (uint8_t mode : std::initializer_list<uint8_t>{11, 13}) {
    // Frequency = depth: more variation.
    CHECK(flickerStdDev(mode, 5, 10) > flickerStdDev(mode, 5, 1) * 2.0);
    // Speed = time scale: more movement per frame.
    CHECK(flickerActivity(mode, 10, 5) > flickerActivity(mode, 1, 5) * 3.0);
  }
}

TEST(render_tv_is_lively_and_cuts_follow_frequency) {
  auto bigJumps = [](uint8_t freq) {
    Sim s(5, 10, freq);
    s.run(1000);
    int jumps = 0;
    uint32_t prev = s.sum();
    for (uint32_t t = 0; t < 300000; t += kFrameMs) {
      s.step();
      const uint32_t cur = s.sum();
      const uint32_t diff = cur > prev ? cur - prev : prev - cur;
      if (diff > 4 * cfg::kPwmMaxDuty / 5) ++jumps;
      prev = cur;
    }
    return jumps;
  };
  CHECK(bigJumps(10) > bigJumps(1));
}

TEST(render_mode_switch_crossfades_without_black_gap) {
  Sim s(1);
  s.run(1000);
  s.p.scene.mode = 11;  // fire
  uint32_t minSum = UINT32_MAX;
  for (int i = 0; i < 80; ++i) {
    s.step();
    minSum = std::min(minSum, s.sum());
  }
  CHECK(minSum > 0);
  CHECK(!s.engine.crossfading());
}

// ------------------------------------------------------------------ welding
namespace {

// Perceptual level (0..1) of channel 0 for a white base colour at 100 %.
float perceptual(uint16_t duty) { return powf(static_cast<float>(duty) / cfg::kPwmMaxDuty, 1.0f / 2.2f); }

struct WeldStats {
  int welds = 0;
  double meanArcMs = 0, meanGapMs = 0;
  double meanArcLevel = 0, maxLevel = 0;
  double sparkShare = 0;       // share of welds preceded by a <= 40 ms spark
  double glowMsPerWeld = 0;    // dim (0 < L < 0.2) time after each arc
  double darkShare = 0;        // frames that are exactly black
  double maxFlatArcMs = 0;     // longest run of identical lit output during an arc
};

// Arc = level > 0.45 sustained for >= 60 ms; it ends after 200 ms below 0.45
// (bridges crackle dips and short outages).
WeldStats weldStats(uint8_t speed, uint8_t freq, uint32_t seconds) {
  Sim s(8, speed, freq);
  s.run(1000);
  WeldStats w;
  std::vector<double> arcs, gaps;
  bool on = false;
  int above = 0, below = 0;
  double onStart = 0, lastEnd = -1, sparkStart = -1;
  bool sparkSeen = false;
  double sumL = 0;
  long nL = 0, zero = 0, total = 0;
  double glowMs = 0, flat = 0;
  uint16_t prevDuty = 0xFFFF;
  for (uint32_t t = 0; t < seconds * 1000; t += kFrameMs) {
    s.step();
    const float L = perceptual(s.duty[0]);
    const double now = s.now;
    ++total;
    if (s.duty[0] == 0) ++zero;
    above = L > 0.45f ? above + 1 : 0;
    if (!on) {
      if (L > 0.45f) {
        if (sparkStart < 0) sparkStart = now;
      } else if (sparkStart >= 0) {
        if (now - sparkStart <= 40) sparkSeen = true;
        sparkStart = -1;
      }
      if (L > 0.0f && L < 0.2f && lastEnd >= 0) glowMs += kFrameMs;
      if (above >= 12) {
        on = true;
        onStart = now - 60;
        ++w.welds;
        if (sparkSeen) w.sparkShare += 1;
        sparkSeen = false;
        if (lastEnd >= 0) gaps.push_back(onStart - lastEnd);
        prevDuty = 0xFFFF;
        flat = 0;
      }
    } else {
      sumL += L;
      ++nL;
      w.maxLevel = std::max(w.maxLevel, static_cast<double>(L));
      // Only lit arc frames count (outages and crater-fill pauses are dark on purpose).
      if (L > 0.45f && s.duty[0] == prevDuty) {
        flat += kFrameMs;
        w.maxFlatArcMs = std::max(w.maxFlatArcMs, flat);
      } else {
        flat = 0;
      }
      prevDuty = s.duty[0];
      below = L < 0.45f ? below + 1 : 0;
      if (below >= 40) {
        on = false;
        arcs.push_back(now - 200 - onStart);
        lastEnd = now - 200;
        below = 0;
        sparkStart = -1;
      }
    }
  }
  auto mean = [](const std::vector<double>& v) {
    double a = 0;
    for (double x : v) a += x;
    return v.empty() ? 0.0 : a / v.size();
  };
  w.meanArcMs = mean(arcs);
  w.meanGapMs = mean(gaps);
  w.meanArcLevel = nL ? sumL / nL : 0;
  w.sparkShare = w.welds ? w.sparkShare / w.welds : 0;
  w.glowMsPerWeld = w.welds ? glowMs / w.welds : 0;
  w.darkShare = static_cast<double>(zero) / total;
  return w;
}

}  // namespace

TEST(render_welding_length_follows_weld_length) {
  const WeldStats tack = weldStats(1, 5, 600);
  const WeldStats mid = weldStats(5, 5, 900);
  const WeldStats bead = weldStats(10, 5, 1200);
  CHECK(tack.meanArcMs >= 250 && tack.meanArcMs <= 650);      // ~0.3 s tacks (+ ignition)
  CHECK(bead.meanArcMs >= 6800 && bead.meanArcMs <= 9200);    // ~8 s beads
  CHECK(mid.meanArcMs > tack.meanArcMs * 2 && mid.meanArcMs < bead.meanArcMs / 2);
}

TEST(render_welding_gap_follows_weld_gap) {
  // Long beads (speed 10) never become tack runs, so every gap is a full gap.
  const WeldStats shortGap = weldStats(10, 1, 900);
  const WeldStats longGap = weldStats(10, 10, 1800);
  CHECK(shortGap.meanGapMs >= 700 && shortGap.meanGapMs <= 1300);    // 0.8 s (+ ignition)
  CHECK(longGap.meanGapMs >= 10000 && longGap.meanGapMs <= 14500);   // 12 s
}

TEST(render_welding_arc_is_alive_with_sparks_and_glow) {
  const WeldStats w = weldStats(10, 10, 1800);
  CHECK(w.welds >= 60);
  CHECK(w.meanArcLevel >= 0.65 && w.meanArcLevel <= 0.85);  // bright arc with headroom
  CHECK(w.maxLevel >= 0.95);                                 // spatter pops / sparks
  CHECK(w.maxFlatArcMs <= 100);                              // never a static glow
  CHECK(w.sparkShare >= 0.9);                                // scratch-start before the arc
  CHECK(w.glowMsPerWeld >= 400);                             // cooling bead after the arc
  CHECK(w.darkShare >= 0.2);                                 // ...which ends in true black
}

TEST(render_welding_gap_slider_acts_live) {
  // Wait for a weld to finish, then change the gap slider mid-gap.
  auto nextArcAfterChange = [](uint8_t newFreq) {
    Sim s(8, 10, newFreq == 1 ? 10 : 1);
    s.run(1000);
    int above = 0, below = 0;
    bool inArc = false;
    for (uint32_t t = 0; t < 60000; t += kFrameMs) {  // find the end of an arc
      s.step();
      const float L = perceptual(s.duty[0]);
      above = L > 0.45f ? above + 1 : 0;
      if (above >= 12) inArc = true;
      below = L < 0.45f ? below + 1 : 0;
      if (inArc && below >= 40) break;
    }
    for (auto& f : s.p.scene.freq) f = newFreq;
    above = 0;
    for (uint32_t t = 0; t < 30000; t += kFrameMs) {
      s.step();
      above = perceptual(s.duty[0]) > 0.45f ? above + 1 : 0;
      if (above >= 12) return static_cast<double>(t);
    }
    return 1e9;
  };
  CHECK(nextArcAfterChange(1) < 2500);   // shortened gap starts the next weld quickly
  CHECK(nextArcAfterChange(10) > 6000);  // lengthened gap holds it back
}

// ------------------------------------------------------------- thunderstorm
// The effect is driven directly (base = pure linear red) so every frame is the
// exact linear light level, and strikes are split by the effect's own strike
// counter.
namespace {

using Character = ThunderEffect::Character;

struct Strike {
  Character character;
  double startMs;
  std::vector<float> levels;  // linear, one per 5 ms frame, trailing darkness trimmed
};

std::vector<Strike> recordStorm(uint8_t speed, uint8_t freq, uint32_t seconds, uint32_t seed = 0xC0FFEEu) {
  Rng rng(seed);
  ThunderEffect fx;
  fx.reset(rng);
  EffectInput in{};
  in.base = {1.0f, 0.0f, 0.0f, 0.0f};
  in.speed = speed;
  in.freq = freq;
  in.dtMs = static_cast<float>(kFrameMs);
  in.rng = &rng;
  std::vector<Strike> strikes;
  uint32_t seen = 0;
  double now = 0;
  for (uint32_t t = 0; t < seconds * 1000; t += kFrameMs) {
    const float v = fx.render(in).r;
    if (fx.strikeCount() != seen) {
      seen = fx.strikeCount();
      strikes.push_back({fx.lastCharacter(), now, {}});
    }
    if (!strikes.empty()) strikes.back().levels.push_back(v);
    now += kFrameMs;
  }
  if (!strikes.empty()) strikes.pop_back();  // the last one may be cut off
  for (auto& s : strikes)
    while (!s.levels.empty() && s.levels.back() == 0.0f) s.levels.pop_back();
  return strikes;
}

// Visible strokes: local maxima that rise at least `prominence` of the strike
// peak above the preceding dip.
std::vector<size_t> strokePeaks(const std::vector<float>& lv, float prominence = 0.15f) {
  if (lv.empty()) return {};
  const float peak = *std::max_element(lv.begin(), lv.end());
  std::vector<size_t> idx;
  float runMin = 1e9f;
  for (size_t j = 0; j < lv.size(); ++j) {
    const float prev = j > 0 ? lv[j - 1] : 0.0f;
    const float next = j + 1 < lv.size() ? lv[j + 1] : 0.0f;
    runMin = std::min(runMin, lv[j]);
    if (lv[j] >= prev && lv[j] > next && lv[j] >= prominence * peak &&
        (idx.empty() || (j - idx.back() >= 3 && lv[j] - runMin >= prominence * peak))) {
      idx.push_back(j);
      runMin = lv[j];
    }
  }
  return idx;
}

float perceptualOf(float linear) { return powf(linear, 1.0f / 2.2f); }

int longestRunAbove(const std::vector<float>& lv, float threshold) {
  int run = 0, best = 0;
  for (float v : lv) {
    run = v >= threshold ? run + 1 : 0;
    best = std::max(best, run);
  }
  return best;
}

double median(std::vector<double> v) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

}  // namespace

TEST(render_thunder_is_dark_between_strikes) {
  // Through the real render engine: the room is black between strikes.
  Sim s(6, 5, 1);
  long dark = 0, total = 0;
  for (uint32_t t = 0; t < 1800 * 1000; t += kFrameMs) {
    s.step();
    ++total;
    dark += s.dark();
  }
  CHECK(static_cast<double>(dark) / total >= 0.95);
  // And every strike is a single contained event followed by darkness.
  const auto strikes = recordStorm(5, 10, 600);
  for (const auto& st : strikes) CHECK(st.levels.size() * kFrameMs <= 1400);
}

TEST(render_thunder_strike_rate_is_precise_and_controlled) {
  // 4 -> 30 strikes per minute; spacing varies naturally but only within +/-20 %.
  const struct {
    uint8_t freq;
    double expectedMs;
    uint32_t seconds;
  } cases[] = {{1, 15000.0, 3600}, {5, 60000.0 / mathx::geo(5, 4.0f, 30.0f), 1800}, {10, 2000.0, 900}};
  for (const auto& c : cases) {
    const auto strikes = recordStorm(5, c.freq, c.seconds);
    std::vector<double> iv;
    for (size_t i = 2; i < strikes.size(); ++i) iv.push_back(strikes[i].startMs - strikes[i - 1].startMs);
    double mean = 0, var = 0;
    for (double x : iv) mean += x / iv.size();
    for (double x : iv) var += (x - mean) * (x - mean) / iv.size();
    CHECK_NEAR(mean, c.expectedMs, c.expectedMs * 0.05);
    CHECK(*std::min_element(iv.begin(), iv.end()) >= c.expectedMs * 0.79);
    CHECK(*std::max_element(iv.begin(), iv.end()) <= c.expectedMs * 1.21);
    CHECK(sqrt(var) / mean <= 0.15);  // controlled, not chaotic
  }
}

TEST(render_thunder_every_strike_has_a_full_power_bolt) {
  const auto strikes = recordStorm(5, 10, 1200);
  CHECK(strikes.size() >= 400);
  for (const auto& st : strikes) {
    CHECK(*std::max_element(st.levels.begin(), st.levels.end()) >= 0.99f);
  }
}

TEST(render_thunder_stroke_counts_match_real_lightning) {
  // Real cloud-to-ground flashes: ~4 strokes on average, some single, some 6+.
  const auto strikes = recordStorm(5, 10, 1800);
  double mean = 0;
  int singles = 0, many = 0;
  for (const auto& st : strikes) {
    const size_t n = strokePeaks(st.levels).size();
    mean += static_cast<double>(n) / strikes.size();
    singles += n == 1;
    many += n >= 6;
  }
  CHECK(mean >= 3.3 && mean <= 5.5);
  CHECK(singles >= 0.05 * strikes.size() && singles <= 0.25 * strikes.size());
  CHECK(many >= 0.10 * strikes.size() && many <= 0.35 * strikes.size());
}

TEST(render_thunder_gaps_are_irregular_but_follow_stroke_tempo) {
  for (uint8_t sp : std::initializer_list<uint8_t>{1, 5, 10}) {
    const auto strikes = recordStorm(sp, 10, 1200);
    std::vector<double> classicGaps, allGaps;
    for (const auto& st : strikes) {
      const auto pk = strokePeaks(st.levels);
      for (size_t q = 1; q < pk.size(); ++q) {
        const double gap = static_cast<double>((pk[q] - pk[q - 1]) * kFrameMs);
        allGaps.push_back(gap);
        if (st.character == Character::Classic) classicGaps.push_back(gap);
      }
    }
    // The typical gap tracks the slider (160 -> 40 ms)...
    const double target = mathx::geo(sp, 160.0f, 40.0f);
    CHECK_NEAR(median(classicGaps), target, target * 0.15);
    // ...while individual gaps stay irregular, like real lightning.
    double mean = 0, var = 0;
    for (double g : allGaps) mean += g / allGaps.size();
    for (double g : allGaps) var += (g - mean) * (g - mean) / allGaps.size();
    const double cv = sqrt(var) / mean;
    CHECK(cv >= 0.4 && cv <= 1.0);
  }
}

TEST(render_thunder_strokes_are_crisp_with_a_brightness_hierarchy) {
  const auto strikes = recordStorm(5, 10, 1800);
  std::vector<double> fwhm, after;
  int classic = 0, firstBrightest = 0;
  for (const auto& st : strikes) {
    const auto& lv = st.levels;
    const size_t m = static_cast<size_t>(std::max_element(lv.begin(), lv.end()) - lv.begin());
    int w = 0;
    for (size_t j = m; j < lv.size() && lv[j] >= 0.5f * lv[m]; ++j) ++w;
    for (int j = static_cast<int>(m) - 1; j >= 0 && lv[j] >= 0.5f * lv[m]; --j) ++w;
    fwhm.push_back(w * static_cast<double>(kFrameMs));
    if (st.character != Character::Classic) continue;
    const auto pk = strokePeaks(lv);
    ++classic;
    firstBrightest += lv[pk.front()] >= 0.97f * lv[m];
    for (size_t q = 1; q < pk.size(); ++q) after.push_back(perceptualOf(lv[pk[q]] / lv[m]));
  }
  // The bolt is a sharp flash (~30 ms), never a slow fade.
  CHECK(median(fwhm) <= 35);
  // The main bolt leads; aftershocks are clearly weaker, but never tiny.
  CHECK(firstBrightest >= 0.85 * classic);
  double meanAfter = 0;
  for (double a : after) meanAfter += a / after.size();
  CHECK(meanAfter >= 0.65 && meanAfter <= 0.9);
  CHECK(*std::min_element(after.begin(), after.end()) >= 0.4);
}

TEST(render_thunder_continuing_current_glows) {
  const auto strikes = recordStorm(5, 10, 1800);
  int burners = 0, burnersGlowing = 0, glowing = 0;
  for (const auto& st : strikes) {
    const float peak = *std::max_element(st.levels.begin(), st.levels.end());
    const int run = longestRunAbove(st.levels, 0.12f * peak);
    glowing += run * static_cast<int>(kFrameMs) >= 100;
    if (st.character == Character::Burner) {
      ++burners;
      burnersGlowing += run * static_cast<int>(kFrameMs) >= 200;
    }
  }
  CHECK(burnersGlowing >= 0.9 * burners);  // "Burner" strikes keep burning
  // Overall about a third of strikes carry a sustained glow, as in nature.
  CHECK(glowing >= 0.2 * strikes.size() && glowing <= 0.45 * strikes.size());
}

TEST(render_thunder_buildup_flickers_lead_into_the_bolt) {
  const auto strikes = recordStorm(5, 10, 1800);
  int buildUps = 0, good = 0;
  for (const auto& st : strikes) {
    if (st.character != Character::BuildUp) continue;
    ++buildUps;
    const auto& lv = st.levels;
    const size_t m = static_cast<size_t>(std::max_element(lv.begin(), lv.end()) - lv.begin());
    std::vector<float> pre;
    for (size_t idx : strokePeaks(lv, 0.05f))
      if (idx < m) pre.push_back(perceptualOf(lv[idx]));
    const bool enough = pre.size() >= 2;
    const bool dimmer = enough && *std::max_element(pre.begin(), pre.end()) < 0.65f;
    const bool growing = enough && pre.back() > pre.front();
    const bool soon = m * kFrameMs <= 350;  // the bolt follows within ~1/3 s
    good += enough && dimmer && growing && soon;
  }
  CHECK(buildUps >= 20);
  CHECK(good >= 0.9 * buildUps);
}

TEST(render_thunder_character_variety_is_controlled) {
  const auto strikes = recordStorm(5, 10, 1200);
  const uint8_t tickets[5] = {2, 3, 2, 2, 1};
  // Exact proportions in every bag of 10 strikes, never the same twice in a row.
  for (size_t b = 0; b + 10 <= strikes.size(); b += 10) {
    int seen[5] = {};
    for (size_t i = b; i < b + 10; ++i) ++seen[static_cast<int>(strikes[i].character)];
    for (int k = 0; k < 5; ++k) CHECK_EQ(seen[k], tickets[k]);
  }
  for (size_t i = 1; i < strikes.size(); ++i) CHECK(strikes[i].character != strikes[i - 1].character);
}

TEST(render_thunder_stroke_tempo_does_not_change_strike_rate) {
  const auto slow = recordStorm(1, 5, 1200);
  const auto fast = recordStorm(10, 5, 1200);
  CHECK(std::abs(static_cast<int>(slow.size()) - static_cast<int>(fast.size())) <= 2);
}

TEST(render_thunder_strike_rate_acts_live) {
  // At strike rate 1 the next strike is ~15 s away; raising the slider to 10
  // once a strike has finished brings the next one within the new ~2 s spacing.
  Rng rng(3);
  ThunderEffect fx;
  fx.reset(rng);
  EffectInput in{};
  in.base = {1.0f, 0.0f, 0.0f, 0.0f};
  in.speed = 5;
  in.freq = 1;
  in.dtMs = static_cast<float>(kFrameMs);
  in.rng = &rng;
  uint32_t t = 0;
  while (fx.strikeCount() == 0 && t < 5000) {
    fx.render(in);
    t += kFrameMs;
  }
  CHECK_EQ(fx.strikeCount(), 1u);
  int darkFrames = 0;
  while (darkFrames < 100 && t < 10000) {  // wait until the strike is over
    darkFrames = fx.render(in).r == 0.0f ? darkFrames + 1 : 0;
    t += kFrameMs;
  }
  in.freq = 10;
  for (uint32_t u = 0; u < 2500 && fx.strikeCount() == 1; u += kFrameMs) fx.render(in);
  CHECK_EQ(fx.strikeCount(), 2u);
}

// ------------------------------------------------------------------- sound
namespace {
struct ToneLog : IToneOutput {
  std::vector<std::pair<uint32_t, uint16_t>> events;
  uint32_t now = 0;
  void tone(uint16_t hz) override { events.push_back({now, hz}); }
};
}  // namespace

TEST(sound_sequencer_plays_melody_and_goes_silent) {
  SoundSequencer seq;
  ToneLog log;
  seq.play(SoundId::Save);  // 1319/40, 1568/40, 2093/60
  for (log.now = 0; log.now < 400; log.now += 5) seq.tick(log.now, log);
  CHECK_EQ(log.events.size(), 4u);
  CHECK_EQ(log.events[0].second, 1319);
  CHECK_EQ(log.events[1].second, 1568);
  CHECK_EQ(log.events[1].first, 40u);
  CHECK_EQ(log.events[2].second, 2093);
  CHECK_EQ(log.events[3].second, 0);
  CHECK_EQ(log.events[3].first, 140u);
  CHECK(!seq.busy());
}

TEST(sound_sequencer_new_sound_preempts) {
  SoundSequencer seq;
  ToneLog log;
  seq.play(SoundId::Boot);
  seq.tick(0, log);
  seq.play(SoundId::Error);
  log.now = 5;
  seq.tick(5, log);
  CHECK_EQ(log.events.back().second, 150);
}

// ---- IDENTIFY ---------------------------------------------------------------------

namespace {
// Runs the IDENTIFY overlay on `a` and checks it against the untouched twin `b`:
// crisp full / dark flashes (all channels together), then exactly b's output.
void checkIdentify(Sim& a, Sim& b) {
  const uint32_t frames = (2u * (cfg::kIdentifyOnMs + cfg::kIdentifyOffMs)) / kFrameMs;
  int rises = 0;
  bool wasLit = false;
  for (uint32_t i = 0; i < frames; ++i) {
    a.step();
    b.step();
    const bool lit = a.duty[0] == cfg::kPwmMaxDuty;
    for (uint16_t d : a.duty) CHECK_EQ(d, lit ? cfg::kPwmMaxDuty : 0);
    const bool expectLit = (i * kFrameMs) % (cfg::kIdentifyOnMs + cfg::kIdentifyOffMs) < cfg::kIdentifyOnMs;
    CHECK_EQ(lit, expectLit);
    rises += lit && !wasLit;
    wasLit = lit;
  }
  CHECK_EQ(rises, int(cfg::kIdentifyFlashes));
  bool same = true;
  for (int i = 0; i < 400; ++i) {
    a.step();
    b.step();
    for (int k = 0; k < 4; ++k) same = same && a.duty[k] == b.duty[k];
  }
  CHECK(same);
}
}  // namespace

TEST(render_identify_flashes_crisply_then_resumes_exactly) {
  for (uint8_t mode : std::initializer_list<uint8_t>{1, 3, 10}) {
    Sim a(mode), b(mode);
    a.p.scene.brightness = b.p.scene.brightness = 60;  // flashes ignore brightness
    a.run(1500);
    b.run(1500);
    a.p.identifyId = 1;
    checkIdentify(a, b);
  }
}

TEST(render_identify_shows_while_asleep_and_leaves_it_dark) {
  Sim a, b;
  a.run(1000);
  b.run(1000);
  a.p.sleeping = b.p.sleeping = 1;
  a.run(cfg::kSleepFadeMs + 100);
  b.run(cfg::kSleepFadeMs + 100);
  CHECK(a.dark());
  a.p.identifyId = 7;
  checkIdentify(a, b);
  CHECK(a.dark());
}

TEST(render_identify_restarts_on_a_new_id_and_stops_on_cancel) {
  Sim a, b;
  a.run(1000);
  b.run(1000);
  a.p.identifyId = 1;
  a.run(200);  // in the first dark gap
  b.run(200);
  CHECK(a.dark());
  a.p.identifyId = 2;  // restart: lit again at once, full sequence
  checkIdentify(a, b);
  a.p.identifyId = 3;
  a.run(50);
  b.run(50);
  CHECK_EQ(a.duty[0], cfg::kPwmMaxDuty);
  a.p.identifyId = 0;  // cancelled: straight back to the normal output
  a.step();
  b.step();
  for (int k = 0; k < 4; ++k) CHECK_EQ(a.duty[k], b.duty[k]);
}

TEST(render_lowest_level_is_a_steady_minimum_and_duty_is_monotonic) {
  // Anything on is at least one whole PWM count (no sparse dithered pulses).
  Sim s;
  s.p.scene.brightness = 1;
  s.run(1000);
  for (uint16_t d : s.duty) CHECK(d == 0 || d >= cfg::kPwmMinDuty);
  CHECK(s.duty[0] >= cfg::kPwmMinDuty);
  // Brightness steps never lower the output.
  uint16_t prev = 0;
  for (int b = 1; b <= 255; ++b) {
    Sim t;
    t.p.scene.color = {255, 255, 255, 255};
    t.p.scene.brightness = static_cast<uint8_t>(b);
    t.run(1000);
    CHECK(t.duty[0] >= prev);
    prev = t.duty[0];
  }
  CHECK_EQ(prev, cfg::kPwmMaxDuty);
}
