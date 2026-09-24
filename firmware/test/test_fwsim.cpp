// fwsim: the platform-glue simulation used by the app's firmware-in-the-loop
// tests must reproduce the device's ingress/egress behaviour exactly.

#include <string>

#include "protocol/BinaryFrame.h"
#include "TestFramework.h"
#include "fwsim/SimDevice.h"

namespace {

void writeText(SimDevice& d, const char* s) { d.write(reinterpret_cast<const uint8_t*>(s), strlen(s)); }

void writeFrame(SimDevice& d, uint8_t seq, Color8 c, uint8_t br) {
  uint8_t f[8];
  binframe::encode8(seq, c, br, f);
  d.write(f, sizeof(f));
}

std::string received(SimDevice& d) {
  std::string s;
  for (const auto& n : d.takeNotifications()) s.append(n.begin(), n.end());
  return s;
}

void connectAndSubscribe(SimDevice& d) {
  d.boot();
  d.connect();
  d.setSubscribed(true);
  d.pass();
  d.takeSounds();
}

}  // namespace

TEST(fwsim_binary_is_applied_before_text_of_the_same_pass) {
  SimDevice d;
  connectAndSubscribe(d);
  writeText(d, "RGBW:1,2,3,4\n");       // arrives first...
  writeFrame(d, 0, {9, 9, 9, 9}, 200);  // ...but the mailbox is drained at step 2
  d.pass();
  CHECK_EQ(d.core().scene().color.r, 1);  // text (step 3) wins
  CHECK_EQ(d.core().scene().brightness, 200);
}

TEST(fwsim_text_overtakes_a_frame_landing_mid_pass) {
  SimDevice d;
  connectAndSubscribe(d);
  d.passBegin();                        // step 2 already ran: mailbox empty
  writeFrame(d, 0, {9, 9, 9, 9}, 200);  // frame written first...
  writeText(d, "RGBW:1,2,3,4\n");       // ...text second
  d.passEnd();                          // text executes now
  CHECK_EQ(d.core().scene().color.r, 1);
  d.pass();                             // the frame lands one pass later
  CHECK_EQ(d.core().scene().color.r, 9);
}

TEST(fwsim_replies_are_chunked_to_the_mtu) {
  SimDevice d;
  connectAndSubscribe(d);
  writeText(d, "STATUS\n");
  d.pass();
  auto notes = d.takeNotifications();
  CHECK(notes.size() >= 4);
  for (const auto& n : notes) CHECK(n.size() <= 20);  // MTU 23 until exchanged
  d.setMtu(247);
  writeText(d, "STATUS\n");
  d.pass();
  notes = d.takeNotifications();
  CHECK_EQ(notes.size(), 1u);
  std::string s(notes[0].begin(), notes[0].end());
  CHECK_STR(s, "STATUS:255,255,255,0,255,1,5,5,0,0,1,0,0,0,1,255,165,0,0,0,0,0,255\n");
}

TEST(fwsim_replies_before_subscription_are_lost) {
  SimDevice d;
  d.boot();
  d.connect();
  d.pass();
  writeText(d, "INFO\n");
  d.pass();
  CHECK(d.takeNotifications().empty());  // "sent" but nobody listened
  CHECK_EQ(d.pendingReplies(), 0u);
  d.setSubscribed(true);
  writeText(d, "INFO\n");
  d.pass();
  CHECK_STR(received(d), "INFO:EB-C3-RGBW-V1\n");
}

TEST(fwsim_failed_notifications_are_retried_next_pass) {
  SimDevice d;
  connectAndSubscribe(d);
  d.failNextNotifies(1);
  writeText(d, "PING\n");
  d.pass();
  CHECK(d.takeNotifications().empty());
  CHECK(d.pendingReplies() > 0);
  d.pass();
  CHECK_STR(received(d), "OK\n");
}

TEST(fwsim_full_stream_drops_whole_writes) {
  SimDevice d;
  connectAndSubscribe(d);
  std::string big(1020, 'A');  // 4 bytes left of the 1024-byte stream
  writeText(d, big.c_str());
  writeText(d, "STATUS\n");  // does not fit: dropped whole, never spliced
  CHECK_EQ(Stats::get(d.stats().rxStreamDrops), 1u);
  CHECK_EQ(d.pendingText(), 1020u);
}

TEST(fwsim_commands_may_span_writes) {
  SimDevice d;
  connectAndSubscribe(d);
  writeText(d, "MOD");
  d.pass();
  writeText(d, "E:4\n");
  d.pass();
  CHECK_EQ(d.core().scene().mode, 4);
  CHECK_STR(received(d), "OK\n");
}

TEST(fwsim_line_reset_discards_a_partial_command) {
  SimDevice d;
  connectAndSubscribe(d);
  writeText(d, "TIMER:8");  // truncated "TIMER:86400" whose tail was lost
  d.pass();
  const uint8_t reset[] = {0x15, 0x0A};  // control byte + terminator
  d.write(reset, sizeof(reset));
  d.pass();
  writeText(d, "PING\n");
  d.pass();
  CHECK(!d.core().timerActive());
  CHECK_STR(received(d), "OK\n");  // no reply for the discarded line
  CHECK_EQ(Stats::get(d.stats().rxRejectedBytes), 1u);
}

TEST(fwsim_reboot_keeps_flash_and_drops_the_link) {
  SimDevice d;
  connectAndSubscribe(d);
  writeText(d, "MODE:6\n");
  writeText(d, "PRESET_SAVE:3\n");
  d.pass();
  d.reboot();
  CHECK(!d.connected());
  CHECK_EQ(d.store().presetMask(), 1u << 3);
  CHECK_EQ(d.core().scene().mode, 1);  // live scene not yet persisted (debounce)
}

TEST(fwsim_timer_expiry_pushes_status) {
  SimDevice d;
  connectAndSubscribe(d);
  d.setMtu(247);
  writeText(d, "TIMER:2\n");
  d.pass();
  CHECK_STR(received(d), "OK\n");
  d.advance(2100);
  CHECK_STR(received(d), "STATUS:255,255,255,0,255,1,5,5,0,0,1,1,0,0,1,255,165,0,0,0,0,0,255\n");
}
