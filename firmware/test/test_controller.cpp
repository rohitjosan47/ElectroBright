// Controller: the app contract, sleep/timer semantics, presets, sound, errors.

#include "protocol/BinaryFrame.h"
#include "Fakes.h"
#include "TestFramework.h"

static bool hasSound(const FakeEnv& env, SoundId id) {
  for (SoundId s : env.sounds)
    if (s == id) return true;
  return false;
}

TEST(ctrl_app_handshake_replies) {
  Rig r;
  r.send("STATUS");
  r.send("MODE_SETTINGS");
  r.send("PRESET_LIST");
  r.send("VERSION");
  r.send("CAPS");
  r.send("INFO");
  CHECK_EQ(r.env.lines.size(), 6u);
  CHECK_STR(r.env.lines[0], "STATUS:255,255,255,0,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,255");
  CHECK_STR(r.env.lines[1].substr(0, 18), "MODE_SETTINGS:5,5;");
  CHECK_STR(r.env.lines[2], "PRESETS:");
  CHECK_STR(r.env.lines[3], "VERSION:3.4.0");
  CHECK_STR(r.env.lines[4], "CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL");
  CHECK_STR(r.env.lines[5], "INFO:EB-C3-RGBW-V1");
}

TEST(ctrl_color_brightness_speed_are_silent_and_published) {
  Rig r;
  r.send("RGBW:1,2,3,4");
  r.send("BRIGHTNESS:77");
  r.send("SPEED:9");
  r.send("FREQUENCY:2");
  CHECK(r.env.lines.empty());  // high-rate commands never reply
  CHECK_EQ(r.env.params.scene.color.g, 2);
  CHECK_EQ(r.env.params.scene.brightness, 77);
  CHECK_EQ(r.core.scene().speed[0], 9);
  CHECK_EQ(r.core.scene().freq[0], 2);
}

TEST(ctrl_speed_frequency_target_active_mode) {
  Rig r;
  r.send("MODE:11");
  r.send("SPEED:8");
  r.send("FREQUENCY:3");
  CHECK_EQ(r.core.scene().speed[10], 8);
  CHECK_EQ(r.core.scene().freq[10], 3);
  CHECK_EQ(r.core.scene().speed[0], 5);  // other modes untouched
  r.send("STATUS");
  CHECK_STR(r.env.last(), "STATUS:255,255,255,0,255,11,8,3,0,0,1,0,0,0,1,255,165,0,0,0,0,0,255");
}

TEST(ctrl_sleep_blocks_colour_wake_but_mode_wakes) {
  Rig r;
  r.send("SLEEP");
  CHECK(r.core.sleeping());
  CHECK_EQ(r.env.params.sleeping, 1);
  CHECK_EQ(r.env.params.fadeMs, cfg::kSleepFadeMs);

  // A late drag packet / RGBW after power-off updates the target only.
  uint8_t pkt[8];
  binframe::encode8(1, {9, 9, 9, 9}, 50, pkt);
  ColorFrame f{};
  CHECK(binframe::decode(pkt, 8, f));
  r.core.onColorFrame(f, r.now);
  r.send("RGBW:1,1,1,1");
  r.send("BRIGHTNESS:10");
  CHECK(r.core.sleeping());
  CHECK_EQ(r.env.params.sleeping, 1);
  CHECK_EQ(r.env.params.scene.brightness, 10);

  r.send("WAKE");
  CHECK(!r.core.sleeping());
  r.send("SLEEP");
  r.send("MODE:4");
  CHECK(!r.core.sleeping());
}

TEST(ctrl_sleep_cancels_timer) {
  Rig r;
  r.send("TIMER:600");
  CHECK(r.core.timerActive());
  r.send("SLEEP");
  CHECK(!r.core.timerActive());
}

TEST(ctrl_timer_expiry_sleeps_and_pushes_status) {
  Rig r;
  r.send("TIMER:30");
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(r.core.timerRemainingSec(r.now), 30u);
  r.advance(10000);
  CHECK_EQ(r.core.timerRemainingSec(r.now), 20u);
  r.env.clear();
  r.advance(20100);
  CHECK(r.core.sleeping());
  CHECK(!r.core.timerActive());
  CHECK_EQ(r.env.params.fadeMs, cfg::kTimerSleepFadeMs);
  CHECK_EQ(r.env.lines.size(), 1u);  // the unsolicited STATUS
  CHECK_STR(r.env.last().substr(0, 7), "STATUS:");
  CHECK(r.env.last().find(",1,0,0,1,") != std::string::npos);  // sleep=1, timer=0, remaining=0, sound=1
}

TEST(ctrl_timer_cancel_and_bounds) {
  Rig r;
  r.send("TIMER:0");
  CHECK_STR(r.env.last(), "OK");
  CHECK(!r.core.timerActive());
  r.send("TIMER:86400");
  CHECK(r.core.timerActive());
  r.send("TIMER:86401");
  CHECK_STR(r.env.last(), "ERROR:FORMAT");
  CHECK(r.core.timerActive());  // an invalid request leaves the timer alone
}

TEST(ctrl_presets_save_load_keep_mute) {
  Rig r;
  r.send("MODE:9");
  r.send("RGBW:10,20,30,40");
  r.send("PRESET_SAVE:4");
  CHECK_STR(r.env.last(), "OK");
  r.send("PRESET_LIST");
  CHECK_STR(r.env.last(), "PRESETS:4,");

  r.send("SOUND_OFF");
  r.send("MODE:1");
  r.send("RGBW:0,0,0,0");
  r.send("SLEEP");
  r.env.clear();
  r.send("PRESET_LOAD:4");
  CHECK_EQ(r.core.scene().mode, 9);
  CHECK_EQ(r.core.scene().color.b, 30);
  CHECK(!r.core.sleeping());                       // loading wakes the light
  CHECK_EQ(r.core.settings().soundEnabled, 0);     // ...but keeps the mute
  CHECK(r.env.sounds.empty());                     // muted: no load chime
  CHECK_STR(r.env.last().substr(0, 7), "STATUS:");  // load answers with STATUS

  r.send("PRESET_LOAD:5");
  CHECK_STR(r.env.last(), "ERROR:PRESET_EMPTY:5");
  r.send("PRESET_DELETE:4");
  CHECK_STR(r.env.last(), "OK");
  r.send("PRESET_LIST");
  CHECK_STR(r.env.last(), "PRESETS:");
}

TEST(ctrl_sound_on_always_confirms_and_persists) {
  Rig r;
  r.send("SOUND_OFF");
  r.env.clear();
  r.send("MODE:2");
  CHECK(r.env.sounds.empty());
  r.send("SOUND_ON");
  CHECK(hasSound(r.env, SoundId::SoundOn));
  CHECK_EQ(r.core.settings().soundEnabled, 1);

  // Persisted immediately (not debounced).
  r.send("SOUND_OFF");
  StateStore store2(r.kv, r.stats);
  Scene s;
  Settings set;
  store2.load(s, set);
  CHECK_EQ(set.soundEnabled, 0);
}

TEST(ctrl_factory_reset_restores_defaults_without_presets) {
  Rig r;
  r.send("MODE:6");
  r.send("PRESET_SAVE:0");
  r.send("SOUND_OFF");
  r.send("TIMER:100");
  r.send("SLEEP");
  r.send("FACTORY_RESET");
  CHECK_STR(r.env.last(), "OK");
  CHECK_EQ(r.core.scene().mode, 1);
  CHECK_EQ(r.core.settings().soundEnabled, 1);
  CHECK(!r.core.sleeping());
  CHECK(!r.core.timerActive());
  r.send("PRESET_LIST");
  CHECK_STR(r.env.last(), "PRESETS:");
}

TEST(ctrl_errors_reply_and_beep) {
  Rig r;
  r.send("MODE:99");
  CHECK_STR(r.env.last(), "ERROR:MODE_INVALID");
  CHECK(hasSound(r.env, SoundId::Error));
  r.send("BOGUS");
  CHECK_STR(r.env.last(), "ERROR:UNKNOWN_CMD");
  CHECK_EQ(Stats::get(r.stats.unknownCommands), 1u);
  CHECK_EQ(r.core.scene().mode, 1);  // state untouched by errors
}

TEST(ctrl_coalesces_bursts_but_keeps_order_of_others) {
  Rig r;
  const char* batch[] = {"RGBW:1,1,1,1", "RGBW:2,2,2,2", "RGBW:3,3,3,3", "MODE:5",
                         "BRIGHTNESS:10", "BRIGHTNESS:20", "STATUS"};
  r.core.processLines(batch, 7, r.now);
  CHECK_EQ(Stats::get(r.stats.coalesced), 3u);
  CHECK_EQ(r.core.scene().color.r, 3);
  CHECK_EQ(r.core.scene().brightness, 20);
  CHECK_EQ(r.env.lines.size(), 2u);  // OK for MODE + STATUS
  CHECK_STR(r.env.lines[1].substr(0, 22), "STATUS:3,3,3,3,20,5,5,");
}

TEST(ctrl_binary_sequence_gaps_are_counted) {
  Rig r;
  ColorFrame f{};
  uint8_t pkt[8];
  const uint8_t seqs[] = {10, 11, 12, 15, 16};
  for (uint8_t s : seqs) {
    binframe::encode8(s, {s, 0, 0, 0}, 255, pkt);
    binframe::decode(pkt, 8, f);
    r.core.onColorFrame(f, r.now);
  }
  CHECK_EQ(Stats::get(r.stats.binarySeqGaps), 1u);
  CHECK_EQ(r.core.scene().color.r, 16);
}

TEST(ctrl_scene_changes_are_persisted_debounced) {
  Rig r;
  r.send("RGBW:5,6,7,8");
  CHECK(r.kv.data.count("scene") == 0);
  r.advance(3100);
  CHECK(r.kv.data.count("scene") == 1);
  StateStore store2(r.kv, r.stats);
  Scene s;
  Settings set;
  store2.load(s, set);
  CHECK_EQ(s.color.b, 7);
}

TEST(ctrl_storage_failure_reported_once) {
  Rig r;
  r.kv.failWrites = true;
  r.send("RGBW:5,6,7,8");
  r.advance(10000);
  int errors = 0;
  for (auto& l : r.env.lines) errors += (l == "ERROR:STORAGE");
  CHECK_EQ(errors, 1);
  r.send("PRESET_SAVE:1");
  CHECK_STR(r.env.last(), "ERROR:STORAGE");  // user actions always report
}

TEST(ctrl_diag_line_is_complete) {
  Rig r;
  r.send("DIAG");
  CHECK_STR(r.env.last().substr(0, 8), "DIAG:rx=");
  CHECK(r.env.last().find(",up=42") != std::string::npos);
}
