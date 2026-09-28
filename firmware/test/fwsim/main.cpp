// fwsim: the real portable firmware core behind a line protocol on
// stdin/stdout, driven by the Flutter app's tests (app/test/support/fwsim/).
//
// Usage: fwsim [--fixture rgbw|rgb|rgbcct|cct|w|none]   (default rgbw)
// The universal firmware built with that type as the default of a first
// install; "none" is a build without a default (setup-needed mode). SET_TYPE
// restarts the simulated light (the link drops) as the new type.
//
// Every request line produces zero or more event lines, then a line ".".
//   HELLO            -> I fwsim/1 fw=<version> model=<model>
//   CONNECT | DISCONNECT | MTU <n> | SUB <0|1> | AUTO <0|1>
//   W <hex>          one BLE write; with AUTO=1 a full control pass follows
//   BEGIN | END | PASS   control pass halves / a full pass
//   ADV <ms>         advance virtual time (idle passes every 50 ms)
//   NFAIL <k>        the next k notifications fail (stack out of buffers)
//   KVFAIL <0|1>     flash writes fail
//   REBOOT           power cycle (flash survives)
//   STATE            -> S {json}   (colours: one value per layout channel)
//   SOUNDS           -> B name,name,...   (and clears the list)
//   QUIT
// After each request, notifications delivered to the phone are reported as
// "N <hex>" lines (in order). Errors: "! <message>".
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#include <vector>

#include "config/Config.h"
#include "../Fixtures.h"
#include "SimDevice.h"

namespace {

bool parseHex(const char* s, std::vector<uint8_t>& out) {
  out.clear();
  const size_t n = strlen(s);
  if (n % 2 != 0) return false;
  for (size_t i = 0; i < n; i += 2) {
    char byte[3] = {s[i], s[i + 1], 0};
    char* end = nullptr;
    const long v = strtol(byte, &end, 16);
    if (end != byte + 2) return false;
    out.push_back(static_cast<uint8_t>(v));
  }
  return true;
}

const char* soundName(SoundId id) {
  switch (id) {
    case SoundId::None: return "None";
    case SoundId::Boot: return "Boot";
    case SoundId::ModeChange: return "ModeChange";
    case SoundId::Save: return "Save";
    case SoundId::Load: return "Load";
    case SoundId::Delete: return "Delete";
    case SoundId::Error: return "Error";
    case SoundId::TimerSet: return "TimerSet";
    case SoundId::TimerCancel: return "TimerCancel";
    case SoundId::Sleep: return "Sleep";
    case SoundId::Wake: return "Wake";
    case SoundId::SoundOn: return "SoundOn";
    case SoundId::FactoryReset: return "FactoryReset";
    case SoundId::Connect: return "Connect";
    case SoundId::Identify: return "Identify";
  }
  return "?";
}

void printColor(std::string& j, const ChannelLayout& l, const Color8& c) {
  uint8_t t[kMaxChannels];
  layout::toTuple(l, c, t);
  j += "[";
  for (uint8_t i = 0; i < l.count; ++i) {
    char b[8];
    snprintf(b, sizeof(b), i ? ",%u" : "%u", t[i]);
    j += b;
  }
  j += "]";
}

void printLevels(std::string& j, const uint8_t* v) {
  j += "[";
  for (uint8_t i = 0; i < cfg::kNumModes; ++i) {
    char b[8];
    snprintf(b, sizeof(b), i ? ",%u" : "%u", v[i]);
    j += b;
  }
  j += "]";
}

std::string stateJson(SimDevice& dev) {
  const Scene& s = dev.core().scene();
  const Stats& st = dev.stats();
  std::string j = "{\"scene\":{\"color\":";
  printColor(j, *dev.fixture().layout, s.color);
  char b[256];
  snprintf(b, sizeof(b), ",\"brightness\":%u,\"mode\":%u,\"speed\":", s.brightness, s.mode);
  j += b;
  printLevels(j, s.speed);
  j += ",\"freq\":";
  printLevels(j, s.freq);
  snprintf(b, sizeof(b), ",\"fireworkColorMode\":%u,\"clubColorMode\":%u,\"policeColorMode\":%u,\"policeA\":",
           s.fireworkColorMode, s.clubColorMode, s.policeColorMode);
  j += b;
  printColor(j, *dev.fixture().layout, s.policeA);
  j += ",\"policeB\":";
  printColor(j, *dev.fixture().layout, s.policeB);
  snprintf(b, sizeof(b),
           "},\"sleeping\":%u,\"timer\":{\"active\":%u,\"remaining\":%lu},\"sound\":%u,\"presets\":[",
           dev.core().sleeping() ? 1u : 0u, dev.core().timerActive() ? 1u : 0u,
           static_cast<unsigned long>(dev.core().timerRemainingSec(dev.now())),
           dev.core().settings().soundEnabled ? 1u : 0u);
  j += b;
  bool first = true;
  for (uint8_t i = 0; i < cfg::kNumPresets; ++i) {
    if (dev.store().presetMask() & (1u << i)) {
      snprintf(b, sizeof(b), first ? "%u" : ",%u", i);
      j += b;
      first = false;
    }
  }
  snprintf(b, sizeof(b),
           "],\"now\":%lu,\"connected\":%u,\"mtu\":%u,\"subscribed\":%u,\"pendingText\":%lu,"
           "\"mailbox\":%u,\"pendingReplies\":%lu,\"render\":{\"sleeping\":%u,\"fadeMs\":%u,\"identify\":%u,"
           "\"probe\":%u},",
           static_cast<unsigned long>(dev.now()), dev.connected() ? 1u : 0u, dev.mtu(), dev.subscribed() ? 1u : 0u,
           static_cast<unsigned long>(dev.pendingText()), dev.mailboxFull() ? 1u : 0u,
           static_cast<unsigned long>(dev.pendingReplies()), dev.lastParams().sleeping, dev.lastParams().fadeMs,
           dev.lastParams().identifyId, dev.lastParams().probe);
  j += b;
  snprintf(b, sizeof(b),
           "\"stats\":{\"rx\":%lu,\"ovf\":%lu,\"rej\":%lu,\"sdrop\":%lu,\"unk\":%lu,\"err\":%lu,\"coal\":%lu,"
           "\"bin\":%lu,\"binbad\":%lu,\"gaps\":%lu,\"nretry\":%lu,\"edrop\":%lu,\"nvsw\":%lu,\"nvsf\":%lu}}",
           static_cast<unsigned long>(Stats::get(st.rxLines)), static_cast<unsigned long>(Stats::get(st.rxLineOverflows)),
           static_cast<unsigned long>(Stats::get(st.rxRejectedBytes)),
           static_cast<unsigned long>(Stats::get(st.rxStreamDrops)),
           static_cast<unsigned long>(Stats::get(st.unknownCommands)),
           static_cast<unsigned long>(Stats::get(st.commandErrors)), static_cast<unsigned long>(Stats::get(st.coalesced)),
           static_cast<unsigned long>(Stats::get(st.binaryOk)), static_cast<unsigned long>(Stats::get(st.binaryBad)),
           static_cast<unsigned long>(Stats::get(st.binarySeqGaps)),
           static_cast<unsigned long>(Stats::get(st.notifyRetries)),
           static_cast<unsigned long>(Stats::get(st.egressDrops)), static_cast<unsigned long>(Stats::get(st.nvsWrites)),
           static_cast<unsigned long>(Stats::get(st.nvsFailures)));
  j += b;
  return j;
}

void emitNotifications(SimDevice& dev) {
  for (const auto& n : dev.takeNotifications()) {
    fputs("N ", stdout);
    for (uint8_t byte : n) printf("%02X", byte);
    fputc('\n', stdout);
  }
}

}  // namespace

int main(int argc, char** argv) {
  const FixtureProfile* fixture = &profiles::kRgbw;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--fixture") == 0 && i + 1 < argc) {
      ++i;
      fixture = strcmp(argv[i], "none") == 0 ? &profiles::kNone : findFixture(argv[i]);
      if (fixture == nullptr) {
        fprintf(stderr, "fwsim: unknown fixture %s\n", argv[i]);
        return 2;
      }
    } else {
      fprintf(stderr, "usage: fwsim [--fixture <name>]\n");
      return 2;
    }
  }
  SimDevice dev(*fixture);
  dev.boot();
  dev.takeSounds();  // boot chime is not interesting to clients
  bool autoPass = true;

  char line[8192];
  std::vector<uint8_t> bytes;
  while (fgets(line, sizeof(line), stdin)) {
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
    char* arg = strchr(line, ' ');
    if (arg) *arg++ = '\0';
    const char* cmd = line;

    if (strcmp(cmd, "QUIT") == 0) break;
    if (strcmp(cmd, "HELLO") == 0) {
      printf("I fwsim/1 fw=%s model=%s\n", cfg::kFirmwareVersion, dev.fixture().modelId);
    } else if (strcmp(cmd, "CONNECT") == 0) {
      dev.connect();
      if (autoPass) dev.pass();
    } else if (strcmp(cmd, "DISCONNECT") == 0) {
      dev.disconnect();
      if (autoPass) dev.pass();
    } else if (strcmp(cmd, "MTU") == 0 && arg) {
      dev.setMtu(static_cast<uint16_t>(atoi(arg)));
    } else if (strcmp(cmd, "SUB") == 0 && arg) {
      dev.setSubscribed(atoi(arg) != 0);
    } else if (strcmp(cmd, "AUTO") == 0 && arg) {
      autoPass = atoi(arg) != 0;
    } else if (strcmp(cmd, "W") == 0 && arg) {
      if (!parseHex(arg, bytes)) {
        puts("! bad hex");
      } else {
        dev.write(bytes.data(), bytes.size());
        if (autoPass) dev.pass();
      }
    } else if (strcmp(cmd, "BEGIN") == 0) {
      dev.passBegin();
    } else if (strcmp(cmd, "END") == 0) {
      dev.passEnd();
    } else if (strcmp(cmd, "PASS") == 0) {
      dev.pass();
    } else if (strcmp(cmd, "ADV") == 0 && arg) {
      dev.advance(static_cast<uint32_t>(strtoul(arg, nullptr, 10)));
    } else if (strcmp(cmd, "NFAIL") == 0 && arg) {
      dev.failNextNotifies(atoi(arg));
    } else if (strcmp(cmd, "KVFAIL") == 0 && arg) {
      dev.flash().failWrites = atoi(arg) != 0;
    } else if (strcmp(cmd, "REBOOT") == 0) {
      dev.reboot();
      dev.takeSounds();
    } else if (strcmp(cmd, "STATE") == 0) {
      printf("S %s\n", stateJson(dev).c_str());
    } else if (strcmp(cmd, "SOUNDS") == 0) {
      std::string s = "B ";
      bool first = true;
      for (SoundId id : dev.takeSounds()) {
        if (!first) s += ",";
        s += soundName(id);
        first = false;
      }
      puts(s.c_str());
    } else {
      printf("! unknown request %s\n", cmd);
    }
    emitNotifications(dev);
    puts(".");
    fflush(stdout);
  }
  return 0;
}
