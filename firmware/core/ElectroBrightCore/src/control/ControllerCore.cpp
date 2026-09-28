#include "ControllerCore.h"

#include <stdio.h>

#include "../config/Config.h"
#include "../fixture/FixtureSelect.h"
#include "../protocol/Replies.h"

namespace {
// Setup-needed mode: what the app needs to find out the wiring and choose a type.
bool allowedInSetup(CmdId id) {
  switch (id) {
    case CmdId::Caps:
    case CmdId::Version:
    case CmdId::Diag:
    case CmdId::Probe:
    case CmdId::Identify:
    case CmdId::SetType:
      return true;
    default:
      return false;
  }
}
}  // namespace

ControllerCore::ControllerCore(IControllerEnv& env, StateStore& store, IKeyValueStore& system, Stats& stats,
                               const FixtureProfile& fixture)
    : env_(env),
      store_(store),
      system_(system),
      stats_(stats),
      fixture_(fixture),
      setup_(fixture.type == FixtureType::None) {
  scene_ = state::defaultScene(fixture_.defaults);
  settings_ = state::defaultSettings();
  fadeMs_ = cfg::kSleepFadeMs;
}

// ------------------------------------------------------------------ lifecycle
void ControllerCore::begin(uint32_t) {
  // Setup-needed mode has no layout to load a scene for; nothing is stored
  // until SET_TYPE.
  if (!setup_) store_.load(scene_, settings_);
  sleeping_ = false;  // sleep is never persisted: power-up means light on
  timerActive_ = false;
  fadeMs_ = cfg::kSleepFadeMs;
  publish();
  sound(SoundId::Boot);
}

void ControllerCore::onConnect(uint32_t) {
  haveSeq_ = false;
  if (cfg::kConnectChirp) sound(SoundId::Connect);
}

void ControllerCore::onDisconnect(uint32_t) { haveSeq_ = false; }

void ControllerCore::tick(uint32_t nowMs) {
  if (probe_ && static_cast<int32_t>(nowMs - probeDeadlineMs_) >= 0) {
    endProbe();
    publish();
  }
  if (restartPending_) return;  // the new type starts from a clean scene
  if (timerActive_ && static_cast<int32_t>(nowMs - timerDeadlineMs_) >= 0) {
    timerActive_ = false;
    endIdentify();
    sleep(cfg::kTimerSleepFadeMs);
    sound(SoundId::Sleep);
    sendStatus(nowMs);  // unsolicited: lets the app update without polling
  }
  checkStorage(store_.tick(nowMs, scene_));
}

uint32_t ControllerCore::timerRemainingSec(uint32_t nowMs) const {
  if (!timerActive_) return 0;
  const int32_t left = static_cast<int32_t>(timerDeadlineMs_ - nowMs);
  if (left <= 0) return 0;
  return (static_cast<uint32_t>(left) + 999u) / 1000u;
}

// ------------------------------------------------------------------ ingress
void ControllerCore::setOtaBusy(bool busy) {
  if (busy == otaBusy_) return;
  otaBusy_ = busy;
  if (busy) {
    endIdentify();
    endProbe();
  }
  publish();
}

void ControllerCore::onColorFrame(const ColorFrame& f, uint32_t nowMs) {
  if (setup_ || restartPending_ || otaBusy_) return;
  endProbe();
  if (f.hasSeq) {
    if (haveSeq_ && f.seq != expectedSeq_) Stats::inc(stats_.binarySeqGaps);
    haveSeq_ = true;
    expectedSeq_ = static_cast<uint8_t>(f.seq + 1);
  }
  endIdentify();
  scene_.color = f.color;
  if (f.hasBrightness) scene_.brightness = f.brightness;
  // Deliberately does NOT wake a sleeping light: a trailing drag packet after
  // "power off" must not switch the fixture back on.
  sceneChanged(nowMs);
  publish();
}

void ControllerCore::processLines(const char* const* lines, size_t count, uint32_t nowMs) {
  size_t i = 0;
  while (i < count) {
    // Parse in chunks so the look-ahead for coalescing never overflows.
    ParseResult results[cfg::kMaxLinesPerBatch];
    const size_t n = (count - i) < cfg::kMaxLinesPerBatch ? (count - i) : cfg::kMaxLinesPerBatch;
    for (size_t k = 0; k < n; ++k) results[k] = parseCommand(lines[i + k], *fixture_.layout);

    for (size_t k = 0; k < n; ++k) {
      if (restartPending_) return;  // SET_TYPE: the rest of the batch is for the old type
      Stats::inc(stats_.rxLines);
      const ParseResult& r = results[k];
      if (r.status == ParseStatus::Unknown) {
        Stats::inc(stats_.unknownCommands);
        reportError(r.errorCode);
        continue;
      }
      if (setup_ && !allowedInSetup(r.cmd.id)) {
        Stats::inc(stats_.commandErrors);
        reportError("SETUP_NEEDED");
        continue;
      }
      if (otaBusy_ && !isQuery(r.cmd.id)) {
        Stats::inc(stats_.commandErrors);
        reportError("BUSY");
        continue;
      }
      if (r.status != ParseStatus::Ok) {
        Stats::inc(stats_.commandErrors);
        reportError(r.errorCode);
        continue;
      }
      if (isCoalescible(r.cmd.id) && k + 1 < n && results[k + 1].status == ParseStatus::Ok &&
          results[k + 1].cmd.id == r.cmd.id) {
        Stats::inc(stats_.coalesced);  // superseded by the next line
        continue;
      }
      execute(r.cmd, nowMs);
    }
    i += n;
  }
}

// ------------------------------------------------------------------ commands
void ControllerCore::execute(const Command& c, uint32_t nowMs) {
  const int32_t* a = c.args;
  // Any state change cancels a running IDENTIFY; the command then applies
  // normally (and republishes if it changes the output).
  if (identifying_ && c.id != CmdId::Identify && !isQuery(c.id)) {
    endIdentify();
    publish();
  }
  // Any other command ends a PROBE.
  if (probe_ && c.id != CmdId::Probe) {
    endProbe();
    publish();
  }
  switch (c.id) {
    case CmdId::Rgbw:
      scene_.color = layout::fromTuple(*fixture_.layout, a);
      sceneChanged(nowMs);
      publish();
      return;  // no reply (high-frequency command)

    case CmdId::Brightness:
      scene_.brightness = static_cast<uint8_t>(a[0]);
      sceneChanged(nowMs);
      publish();
      return;

    case CmdId::Mode:
      scene_.mode = static_cast<uint8_t>(a[0]);
      wake();
      sceneChanged(nowMs);
      publish();
      sound(SoundId::ModeChange);
      env_.sendLine("OK");
      return;

    case CmdId::Speed:
      scene_.speed[scene_.mode - 1] = static_cast<uint8_t>(a[0]);
      sceneChanged(nowMs);
      publish();
      return;

    case CmdId::Frequency:
      scene_.freq[scene_.mode - 1] = static_cast<uint8_t>(a[0]);
      sceneChanged(nowMs);
      publish();
      return;

    case CmdId::ModeSpeed:
      scene_.speed[a[0] - 1] = static_cast<uint8_t>(a[1]);
      sceneChanged(nowMs);
      publish();
      env_.sendLine("OK");
      return;

    case CmdId::ModeFrequency:
      scene_.freq[a[0] - 1] = static_cast<uint8_t>(a[1]);
      sceneChanged(nowMs);
      publish();
      env_.sendLine("OK");
      return;

    case CmdId::FireworkColorMode:
    case CmdId::ClubColorMode:
    case CmdId::PoliceColorMode: {
      uint8_t& field = c.id == CmdId::FireworkColorMode ? scene_.fireworkColorMode
                       : c.id == CmdId::ClubColorMode   ? scene_.clubColorMode
                                                        : scene_.policeColorMode;
      field = static_cast<uint8_t>(a[0]);
      sceneChanged(nowMs);
      publish();
      env_.sendLine("OK");
      return;
    }

    case CmdId::PoliceColorA:
    case CmdId::PoliceColorB: {
      Color8& target = c.id == CmdId::PoliceColorA ? scene_.policeA : scene_.policeB;
      target = layout::fromTuple(*fixture_.layout, a);
      sceneChanged(nowMs);
      publish();
      env_.sendLine("OK");
      return;
    }

    case CmdId::PresetSave: {
      if (store_.savePreset(static_cast<uint8_t>(a[0]), scene_)) {
        sound(SoundId::Save);
        env_.sendLine("OK");
      } else {
        reportError("STORAGE");  // user action: always report
      }
      return;
    }

    case CmdId::PresetLoad: {
      const uint8_t id = static_cast<uint8_t>(a[0]);
      Scene loaded;
      if (store_.loadPreset(id, loaded)) {
        scene_ = loaded;  // settings (mute) are not part of a preset
        wake();
        sceneChanged(nowMs);
        publish();
        sound(SoundId::Load);
        sendStatus(nowMs);
      } else {
        replies::presetEmpty(buf_, sizeof(buf_), id);
        env_.sendLine(buf_);
        sound(SoundId::Error);
      }
      return;
    }

    case CmdId::PresetDelete: {
      if (store_.deletePreset(static_cast<uint8_t>(a[0]))) {
        sound(SoundId::Delete);
        env_.sendLine("OK");
      } else {
        reportError("STORAGE");
      }
      return;
    }

    case CmdId::PresetList:
      replies::presets(buf_, sizeof(buf_), store_.presetMask());
      env_.sendLine(buf_);
      return;

    case CmdId::Status:
      sendStatus(nowMs);
      return;

    case CmdId::ModeSettings:
      replies::modeSettings(buf_, sizeof(buf_), scene_);
      env_.sendLine(buf_);
      return;

    case CmdId::ModeCapabilities:
      replies::capabilities(buf_, sizeof(buf_), static_cast<uint8_t>(a[0]));
      env_.sendLine(buf_);
      return;

    case CmdId::Sleep:
      timerActive_ = false;
      if (!sleeping_) sound(SoundId::Sleep);
      sleep(cfg::kSleepFadeMs);
      env_.sendLine("OK");
      return;

    case CmdId::Wake:
      if (sleeping_) sound(SoundId::Wake);
      wake();
      publish();
      env_.sendLine("OK");
      return;

    case CmdId::SoundOn:
      settings_.soundEnabled = 1;
      checkStorage(store_.saveSettings(settings_));
      env_.playSound(SoundId::SoundOn);  // always audible: confirms un-muting
      env_.sendLine("OK");
      return;

    case CmdId::SoundOff:
      settings_.soundEnabled = 0;
      checkStorage(store_.saveSettings(settings_));
      env_.sendLine("OK");
      return;

    case CmdId::Timer:
      if (a[0] == 0) {
        if (timerActive_) sound(SoundId::TimerCancel);
        timerActive_ = false;
      } else {
        timerActive_ = true;
        timerDeadlineMs_ = nowMs + static_cast<uint32_t>(a[0]) * 1000u;
        sound(SoundId::TimerSet);
      }
      env_.sendLine("OK");
      return;

    case CmdId::FactoryReset:
      checkStorage(store_.factoryReset());
      scene_ = state::defaultScene(fixture_.defaults);
      settings_ = state::defaultSettings();
      timerActive_ = false;
      wake();
      publish();
      sound(SoundId::FactoryReset);
      env_.sendLine("OK");  // no reboot: the app re-queries on the same link
      return;

    case CmdId::Info:
      snprintf(buf_, sizeof(buf_), "INFO:%s", fixture_.modelId);
      env_.sendLine(buf_);
      return;

    case CmdId::Version:
      snprintf(buf_, sizeof(buf_), "VERSION:%s", cfg::kFirmwareVersion);
      env_.sendLine(buf_);
      return;

    case CmdId::Caps:
      replies::caps(buf_, sizeof(buf_), fixture_);
      env_.sendLine(buf_);
      return;

    case CmdId::Ping:
      env_.sendLine("OK");
      return;

    case CmdId::Diag:
      sendDiag();
      return;

    case CmdId::Identify:
      if (setup_) {
        // No LED output is known yet: the buzzer only, whatever the mute setting.
        env_.playSound(SoundId::Identify);
        env_.sendLine("OK");
        return;
      }
      // Flashes the light on top of whatever it shows (even asleep) and then
      // resumes it; no state changes, nothing persists, no Sleep/Wake sounds.
      // A fresh id every time, so the renderer restarts even if it never saw
      // the cancelled snapshot in between.
      identifySeq_ = static_cast<uint16_t>(identifySeq_ + 1);
      if (identifySeq_ == 0) identifySeq_ = 1;
      identifying_ = true;
      publish();
      sound(SoundId::Identify);
      env_.sendLine("OK");
      return;

    case CmdId::SetType:
      setType(static_cast<FixtureType>(a[0]));
      return;

    case CmdId::Probe: {
      // One output at a time; nothing persists, the light's state is untouched.
      const uint8_t output = static_cast<uint8_t>(a[0] + 1);
      if (a[1]) {
        probe_ = output;
        probeDeadlineMs_ = nowMs + cfg::kProbeMs;
      } else if (probe_ == output) {
        endProbe();
      }
      publish();
      env_.sendLine("OK");
      return;
    }
  }
}

// ------------------------------------------------------------------ helpers
void ControllerCore::reportError(const char* code) {
  replies::error(buf_, sizeof(buf_), code);
  env_.sendLine(buf_);
  sound(SoundId::Error);
}

void ControllerCore::sound(SoundId id) {
  if (settings_.soundEnabled) env_.playSound(id);
}

void ControllerCore::publish() {
  RenderParams p;
  p.scene = scene_;
  p.sleeping = sleeping_ ? 1 : 0;
  p.fadeMs = fadeMs_;
  p.identifyId = identifying_ ? identifySeq_ : 0;
  p.probe = probe_;
  p.ota = otaBusy_ ? 1 : 0;
  env_.publish(p);
}

void ControllerCore::endIdentify() { identifying_ = false; }

void ControllerCore::endProbe() { probe_ = 0; }

void ControllerCore::setType(FixtureType type) {
  if (type == fixture_.type) {
    env_.sendLine("OK");  // already this type: nothing changes
    return;
  }
  // Presets and the scene belong to the old layout. They go first and the type
  // last, so a power cut in between leaves the old type with its defaults.
  bool ok = store_.clearForTypeChange();
  if (ok) {
    ok = fxselect::write(system_, type);
    Stats::inc(ok ? stats_.nvsWrites : stats_.nvsFailures);
  }
  if (!ok) {
    reportError("STORAGE");  // the type is unchanged; no restart
    return;
  }
  restartPending_ = true;
  env_.sendLine("OK");
  env_.restart();  // boots as the new type, with its defaults
}

void ControllerCore::sceneChanged(uint32_t nowMs) { store_.noteSceneChanged(nowMs); }

void ControllerCore::wake() {
  if (sleeping_) {
    sleeping_ = false;
    fadeMs_ = cfg::kSleepFadeMs;
  }
}

void ControllerCore::sleep(uint16_t fadeMs) {
  sleeping_ = true;
  fadeMs_ = fadeMs;
  publish();
}

void ControllerCore::sendStatus(uint32_t nowMs) {
  StatusView v{&scene_, sleeping_, timerActive_, timerRemainingSec(nowMs), settings_.soundEnabled != 0,
               fixture_.layout};
  replies::status(buf_, sizeof(buf_), v);
  env_.sendLine(buf_);
}

void ControllerCore::sendDiag() {
  SystemDiag d;
  env_.systemDiag(d);
  snprintf(buf_, sizeof(buf_),
           "DIAG:rx=%lu,ovf=%lu,rej=%lu,sdrop=%lu,unk=%lu,err=%lu,coal=%lu,bin=%lu,binbad=%lu,gaps=%lu,"
           "nretry=%lu,edrop=%lu,nvsw=%lu,nvsf=%lu,frames=%lu,overrun=%lu,rmaxus=%lu,heapmin=%lu,"
           "stkc=%lu,stkr=%lu,rst=%lu,up=%lu,slot=%lu,rb=%lu",
           (unsigned long)Stats::get(stats_.rxLines), (unsigned long)Stats::get(stats_.rxLineOverflows),
           (unsigned long)Stats::get(stats_.rxRejectedBytes), (unsigned long)Stats::get(stats_.rxStreamDrops),
           (unsigned long)Stats::get(stats_.unknownCommands), (unsigned long)Stats::get(stats_.commandErrors),
           (unsigned long)Stats::get(stats_.coalesced), (unsigned long)Stats::get(stats_.binaryOk),
           (unsigned long)Stats::get(stats_.binaryBad), (unsigned long)Stats::get(stats_.binarySeqGaps),
           (unsigned long)Stats::get(stats_.notifyRetries), (unsigned long)Stats::get(stats_.egressDrops),
           (unsigned long)Stats::get(stats_.nvsWrites), (unsigned long)Stats::get(stats_.nvsFailures),
           (unsigned long)Stats::get(stats_.renderFrames), (unsigned long)Stats::get(stats_.renderOverruns),
           (unsigned long)Stats::get(stats_.renderMaxUs), (unsigned long)d.minFreeHeap,
           (unsigned long)d.controlStackFree, (unsigned long)d.renderStackFree, (unsigned long)d.resetReason,
           (unsigned long)d.uptimeSec, (unsigned long)d.runningSlot, (unsigned long)d.rolledBack);
  env_.sendLine(buf_);
}

void ControllerCore::checkStorage(bool ok) {
  if (ok || storageErrorReported_) return;
  storageErrorReported_ = true;  // report once per boot; DIAG keeps counting
  reportError("STORAGE");
}
