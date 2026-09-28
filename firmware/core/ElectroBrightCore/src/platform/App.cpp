#include "App.h"

#include <esp_log.h>
#include <esp_random.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/stream_buffer.h>
#include <freertos/task.h>
#include <string.h>

#include <atomic>

#include "../config/Config.h"
#include "../control/ControllerCore.h"
#include "../core/SeqLock.h"
#include "../core/Stats.h"
#include "../feedback/SoundSequencer.h"
#include "../fixture/FixtureSelect.h"
#include "../protocol/Egress.h"
#include "../protocol/LineAssembler.h"
#include "../render/RenderEngine.h"
#include "../state/StateStore.h"
#include "BleNus.h"
#include "Buzzer.h"
#include "NvsStore.h"
#include "PwmOutput.h"

namespace {

constexpr const char* kTag = "EB";

// ---- Shared objects (static storage, no heap) --------------------------------
const FixtureProfile* g_fixture = nullptr;  // the active type's profile (profiles::kNone: setup needed)
Stats g_stats;
PwmOutput g_pwm;
Buzzer g_buzzer;
NvsStore g_nvs;     // settings, scene, presets
NvsStore g_system;  // the fixture type
std::atomic<uint32_t> g_restartAtMs{0};  // SET_TYPE: restart due (0 = none)
SoundSequencer g_sound;
SeqLock<RenderParams> g_params;
Egress g_egress;  // control task only
// Built in App::start() once the fixture is known (function-local statics).
RenderEngine* g_engine = nullptr;
ControllerCore* g_core = nullptr;

StreamBufferHandle_t g_rxText = nullptr;
QueueHandle_t g_colorMailbox = nullptr;
QueueHandle_t g_events = nullptr;
TaskHandle_t g_controlTask = nullptr;
TaskHandle_t g_renderTask = nullptr;
esp_timer_handle_t g_frameTimer = nullptr;

inline uint32_t nowMs() { return static_cast<uint32_t>(esp_timer_get_time() / 1000); }

// ---- Controller environment ----------------------------------------------------
class DeviceEnv final : public IControllerEnv {
 public:
  void sendLine(const char* line) override {
    if (!g_egress.push(line)) Stats::inc(g_stats.egressDrops);
  }
  void publish(const RenderParams& p) override { g_params.write(p); }
  void playSound(SoundId id) override { g_sound.play(id); }
  void systemDiag(SystemDiag& d) override {
    d.minFreeHeap = esp_get_minimum_free_heap_size();
    d.controlStackFree = g_controlTask ? uxTaskGetStackHighWaterMark(g_controlTask) : 0;
    d.renderStackFree = g_renderTask ? uxTaskGetStackHighWaterMark(g_renderTask) : 0;
    d.resetReason = static_cast<uint32_t>(esp_reset_reason());
    d.uptimeSec = static_cast<uint32_t>(esp_timer_get_time() / 1000000);
  }
  void restart() override {
    const uint32_t at = nowMs() + cfg::kRestartDelayMs;
    g_restartAtMs = at ? at : 1;
  }
};

DeviceEnv g_env;

// ---- Control task: the only owner of device state ------------------------------
void controlTask(void*) {
  esp_task_wdt_add(nullptr);

  static LineAssembler assembler;
  static char lines[cfg::kMaxLinesPerBatch][cfg::kMaxLineLength + 1];
  const char* linePtrs[cfg::kMaxLinesPerBatch];
  uint8_t chunk[128];
  LineAssembler::Counters seen{};

  for (;;) {
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(cfg::kControlWakeMs));
    const uint32_t now = nowMs();

    // 1. Connection lifecycle.
    uint8_t ev;
    while (xQueueReceive(g_events, &ev, 0) == pdTRUE) {
      g_egress.clear();  // never deliver a previous session's replies
      assembler.reset();
      if (ev == static_cast<uint8_t>(BleEvent::Connected)) {
        g_core->onConnect(now);
      } else {
        g_core->onDisconnect(now);
      }
    }

    // 2. Latest binary colour (older ones were overwritten in the mailbox).
    ColorFrame frame;
    if (xQueueReceive(g_colorMailbox, &frame, 0) == pdTRUE) g_core->onColorFrame(frame, now);

    // 3. Text commands, executed in batches (enables coalescing).
    size_t count = 0;
    auto flushBatch = [&]() {
      if (count > 0) {
        g_core->processLines(linePtrs, count, now);
        count = 0;
      }
    };
    size_t got;
    while ((got = xStreamBufferReceive(g_rxText, chunk, sizeof(chunk), 0)) > 0) {
      assembler.feed(chunk, got, [&](const char* line, size_t len) {
        memcpy(lines[count], line, len + 1);
        linePtrs[count] = lines[count];
        if (++count == cfg::kMaxLinesPerBatch) flushBatch();
      });
    }
    flushBatch();

    const LineAssembler::Counters& c = assembler.counters();
    Stats::inc(g_stats.rxLineOverflows, c.overflows - seen.overflows);
    Stats::inc(g_stats.rxRejectedBytes, c.rejected - seen.rejected);
    seen = c;

    // 4. Timer expiry + persistence.
    g_core->tick(now);

    // 5. Replies.
    if (ble::connected()) {
      const uint32_t retriesBefore = g_egress.retries();
      g_egress.flush(ble::maxPayload(), [](const uint8_t* d, size_t n) { return ble::notify(d, n); });
      Stats::inc(g_stats.notifyRetries, g_egress.retries() - retriesBefore);
    } else {
      g_egress.clear();
    }

    // 6. SET_TYPE: restart once the OK has gone out (and had time to leave).
    const uint32_t restartAt = g_restartAtMs.load();
    if (restartAt && (g_egress.pending() == 0 || !ble::connected()) &&
        static_cast<int32_t>(nowMs() - restartAt) >= 0) {
      ESP_LOGI(kTag, "fixture type changed: restarting");
      esp_restart();
    }

    esp_task_wdt_reset();
  }
}

// ---- Render task: fixed 200 Hz frames ---------------------------------------------
void onFrameTimer(void*) {
  if (g_renderTask) xTaskNotifyGive(g_renderTask);
}

void renderTask(void*) {
  esp_task_wdt_add(nullptr);
  RenderParams params{};
  g_params.tryRead(params);  // published by g_core->begin() before this task starts
  uint16_t duty[kMaxChannels] = {};

  for (;;) {
    const uint32_t pending = ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(50));
    if (pending > 1) Stats::inc(g_stats.renderOverruns, pending - 1);

    const int64_t t0 = esp_timer_get_time();
    g_params.tryRead(params);  // on a torn read keep last frame's params
    const uint32_t now = static_cast<uint32_t>(t0 / 1000);
    g_engine->frame(params, now, duty);
    g_pwm.probe(probe::apply(*g_fixture, params.probe, duty));
    g_pwm.write(duty);
    g_sound.tick(now, g_buzzer);

    Stats::inc(g_stats.renderFrames);
    Stats::max(g_stats.renderMaxUs, static_cast<uint32_t>(esp_timer_get_time() - t0));
    esp_task_wdt_reset();
  }
}

void configureWatchdog() {
  esp_task_wdt_config_t wdt = {};
  wdt.timeout_ms = cfg::kWatchdogTimeoutMs;
  wdt.idle_core_mask = (1u << portNUM_PROCESSORS) - 1;  // also catch CPU starvation
  wdt.trigger_panic = true;                              // reboot instead of hanging
  if (esp_task_wdt_init(&wdt) == ESP_ERR_INVALID_STATE) {
    esp_task_wdt_reconfigure(&wdt);  // the Arduino core already started it
  }
}

}  // namespace

namespace App {

void start(FixtureType buildDefault) {
  // 1. Outputs first: every board LED output held low from the earliest
  // moment, before the type is known.
  PwmOutput::holdLow(profiles::kNone);

  // 2. Storage (clean start: the old firmware's EEPROM data is discarded) and
  // the fixture type.
  NvsStore::wipeNamespace(cfg::kLegacyNvsNamespace);
  if (!g_system.begin(cfg::kSystemNvsNamespace)) ESP_LOGE(kTag, "NVS unavailable: fixture type unknown");
  g_fixture = &fxselect::select(g_system, buildDefault);
  if (!g_nvs.begin(cfg::kNvsNamespace)) ESP_LOGE(kTag, "NVS unavailable; running with defaults");

  // 3. The active type's outputs at 0 %, its unused ones held low.
  if (!g_pwm.begin(*g_fixture)) ESP_LOGE(kTag, "LEDC init failed");
  // The buzzer takes the first LEDC channel after the LED outputs.
  if (!g_buzzer.begin(g_fixture->buzzerPin, g_fixture->layout->count)) ESP_LOGW(kTag, "buzzer init failed");

  configureWatchdog();

  // 4. State + first render snapshot (the renderer fades in from black).
  static StateStore store(g_nvs, g_stats, *g_fixture);
  static RenderEngine engine(0x5EEDu, *g_fixture->layout, g_fixture->whiteMix);
  static ControllerCore core(g_env, store, g_system, g_stats, *g_fixture);
  g_engine = &engine;
  g_core = &core;
  g_engine->reseed(esp_random());
  g_core->begin(nowMs());

  // 5. IPC + tasks.
  g_rxText = xStreamBufferCreate(cfg::kRxStreamBytes, 1);
  g_colorMailbox = xQueueCreate(1, sizeof(ColorFrame));
  g_events = xQueueCreate(8, sizeof(uint8_t));
  xTaskCreate(renderTask, "eb-render", cfg::kRenderStackBytes, nullptr, cfg::kRenderPriority, &g_renderTask);
  xTaskCreate(controlTask, "eb-control", cfg::kControlStackBytes, nullptr, cfg::kControlPriority, &g_controlTask);

  // 6. Fixed-rate frame clock.
  esp_timer_create_args_t timerArgs = {};
  timerArgs.callback = onFrameTimer;
  timerArgs.name = "eb-frame";
  esp_timer_create(&timerArgs, &g_frameTimer);
  esp_timer_start_periodic(g_frameTimer, cfg::kRenderPeriodUs);

  // 7. Radio last: by now every consumer of its callbacks exists.
  BleSinks sinks{g_rxText, g_colorMailbox, g_events, g_controlTask, &g_stats};
  if (!ble::begin(sinks, *g_fixture)) ESP_LOGE(kTag, "BLE advertising failed to start");

  ESP_LOGI(kTag, "ElectroBright %s %s ready", g_fixture->modelId, cfg::kFirmwareVersion);
}

}  // namespace App
