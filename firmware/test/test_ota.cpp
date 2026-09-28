// Wireless updates (3.8.0): SHA-256, the image identity block, the receiver's
// protocol (full transfer, resume, duplicates and gaps, every error), the
// busy light during a transfer, and the first-boot self-check with rollback,
// on the fake two-slot flash and bootloader (Fakes.h MockOtaFlash).

#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

#include "Fakes.h"
#include "TestFramework.h"
#include "fwsim/SimDevice.h"
#include "ota/ImageIdentity.h"
#include "ota/OtaProtocol.h"
#include "ota/OtaReceiver.h"
#include "ota/SelfCheck.h"
#include "ota/Sha256.h"
#include "render/OtaGlow.h"

namespace {

using Bytes = std::vector<uint8_t>;

std::string hex(const uint8_t* d, size_t n) {
  static const char* k = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; ++i) {
    s += k[d[i] >> 4];
    s += k[d[i] & 15];
  }
  return s;
}

std::string sha(const std::string& text) {
  Sha256 h;
  h.update(reinterpret_cast<const uint8_t*>(text.data()), text.size());
  uint8_t d[32];
  h.digest(d);
  return hex(d, 32);
}

void putU32(uint8_t* p, uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}
uint32_t getU32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

// A fake firmware image: the ESP image magic, an identity block at 0x120 (as
// the linker places it), then pseudo-random bytes.
Bytes makeImage(size_t size, const char* version = "3.9.0", const char* product = "ElectroBright",
                const char* kind = "universal", bool withIdentity = true) {
  Bytes img(size);
  uint32_t x = 12345;
  for (size_t i = 0; i < size; ++i) {
    x = x * 1103515245u + 12345u;
    img[i] = static_cast<uint8_t>(x >> 16);
  }
  if (size > 0) img[0] = 0xE9;
  if (withIdentity && size >= 0x120 + sizeof(ImageIdentity)) {
    ImageIdentity id{};
    memcpy(id.magic, imageid::kMagic, sizeof(id.magic));
    strncpy(id.product, product, sizeof(id.product) - 1);
    strncpy(id.kind, kind, sizeof(id.kind) - 1);
    strncpy(id.version, version, sizeof(id.version) - 1);
    memcpy(img.data() + 0x120, &id, sizeof(id));
  }
  return img;
}

void digestOf(const Bytes& img, uint8_t out[32]) {
  Sha256 h;
  h.update(img.data(), img.size());
  h.digest(out);
}

Bytes beginMsg(const Bytes& img, uint16_t major, uint16_t minor, uint16_t patch, bool reinstall = false,
               const uint8_t* hash = nullptr) {
  Bytes m(ota::kBeginLength);
  m[0] = ota::kBegin;
  putU32(&m[1], static_cast<uint32_t>(img.size()));
  uint8_t d[32];
  digestOf(img, d);
  memcpy(&m[5], hash ? hash : d, 32);
  const uint16_t v[3] = {major, minor, patch};
  for (int i = 0; i < 3; ++i) {
    m[37 + 2 * i] = static_cast<uint8_t>(v[i]);
    m[38 + 2 * i] = static_cast<uint8_t>(v[i] >> 8);
  }
  m[43] = reinstall ? ota::kFlagReinstall : 0;
  return m;
}

Bytes dataMsg(const Bytes& img, uint32_t offset, size_t len) {
  Bytes m(4 + len);
  putU32(m.data(), offset);
  memcpy(m.data() + 4, img.data() + offset, len);
  return m;
}

// A receiver on the fake flash, running firmware 3.8.0.
struct OtaRig : IOtaEnv {
  MockOtaFlash flash;
  std::vector<Bytes> replies;
  int activeOn = 0, activeOff = 0, restarts = 0;
  bool isActive = false;
  OtaReceiver rx{flash, *this, FirmwareVersion{3, 8, 0}};
  uint32_t now = 1000;

  void otaReply(const uint8_t* d, size_t n) override { replies.emplace_back(d, d + n); }
  void otaActive(bool a) override {
    isActive = a;
    ++(a ? activeOn : activeOff);
  }
  void otaRestart() override { ++restarts; }

  Bytes control(const Bytes& m) {
    replies.clear();
    rx.onControl(m.data(), m.size(), now);
    return replies.empty() ? Bytes() : replies.back();
  }
  void data(const Bytes& m) { rx.onData(m.data(), m.size(), now); }
  // Sends [from, to) in chunks of `chunk` bytes.
  void send(const Bytes& img, uint32_t from, uint32_t to, size_t chunk = 240) {
    for (uint32_t off = from; off < to;) {
      const size_t n = (to - off) < chunk ? (to - off) : chunk;
      data(dataMsg(img, off, n));
      off += static_cast<uint32_t>(n);
    }
  }
};

bool isError(const Bytes& r, ota::Error e) { return r.size() == 6 && r[0] == ota::kError && r[1] == uint8_t(e); }

uint32_t beginStart(const Bytes& r) { return r.size() == 7 && r[0] == ota::kBeginOk ? getU32(&r[1]) : 0xFFFFFFFF; }

std::vector<uint32_t> acks(const std::vector<Bytes>& rs) {
  std::vector<uint32_t> out;
  for (const Bytes& r : rs) {
    if (r.size() == 5 && r[0] == ota::kAck) out.push_back(getU32(&r[1]));
  }
  return out;
}

const Bytes kEnd = {ota::kEnd};
const Bytes kAbort = {ota::kAbort};
const Bytes kStatus = {ota::kStatus};

}  // namespace

// ---- SHA-256 and identity ---------------------------------------------------------------

TEST(ota_sha256_known_vectors) {
  CHECK_STR(sha(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  CHECK_STR(sha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK_STR(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
  // A million 'a' (fed 1000 at a time).
  std::string a(1000, 'a');
  Sha256 m;
  for (int i = 0; i < 1000; ++i) m.update(reinterpret_cast<const uint8_t*>(a.data()), a.size());
  uint8_t d[32];
  m.digest(d);
  CHECK_STR(hex(d, 32), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
  // digest() leaves the running state alone.
  Sha256 s;
  s.update(reinterpret_cast<const uint8_t*>("ab"), 2);
  s.digest(d);
  s.update(reinterpret_cast<const uint8_t*>("c"), 1);
  s.digest(d);
  CHECK_STR(hex(d, 32), sha("abc"));
}

TEST(ota_identity_block_of_this_firmware) {
  const ImageIdentity& id = imageid::running();
  CHECK(imageid::isUniversal(id));
  CHECK_STR(id.version, cfg::kFirmwareVersion);
  CHECK_STR(id.product, "ElectroBright");
  CHECK_STR(id.kind, "universal");
  FirmwareVersion v;
  CHECK(imageid::parseVersion("3.8.0", v) && v.major == 3 && v.minor == 8 && v.patch == 0);
  for (const char* bad : {"", "3", "3.8", "3.8.0.1", "3..0", "a.b.c", "3.8.0 ", "70000.0.0"}) {
    CHECK(!imageid::parseVersion(bad, v));
  }
  CHECK(imageid::compare({3, 8, 0}, {3, 7, 9}) > 0);
  CHECK(imageid::compare({3, 8, 0}, {3, 8, 0}) == 0);
  CHECK(imageid::compare({3, 8, 0}, {4, 0, 0}) < 0);
  // Found anywhere 4-aligned in the head, and only there.
  const Bytes img = makeImage(4096);
  ImageIdentity found;
  CHECK(imageid::find(img.data(), img.size(), found) && imageid::isUniversal(found));
  CHECK(!imageid::find(img.data(), 0x120, found));
  CHECK(!imageid::isUniversal(*reinterpret_cast<const ImageIdentity*>(makeImage(4096, "9.0.0", "Other").data() + 0x120)));
  CHECK(!imageid::isUniversal(
      *reinterpret_cast<const ImageIdentity*>(makeImage(4096, "9.0.0", "ElectroBright", "rgbw").data() + 0x120)));
}

// ---- The receiver ------------------------------------------------------------------------

TEST(ota_full_transfer_verifies_then_switches) {
  OtaRig r;
  const Bytes img = makeImage(50000);
  const Bytes b = r.control(beginMsg(img, 3, 9, 0));
  CHECK_EQ(beginStart(b), 0u);
  CHECK_EQ(b[5] | (b[6] << 8), static_cast<int>(ota::kWindow));
  CHECK(r.isActive);
  r.replies.clear();
  r.send(img, 0, static_cast<uint32_t>(img.size()));
  // One ACK per 8 KB window, and one at the end.
  const std::vector<uint32_t> a = acks(r.replies);
  CHECK_EQ(a.size(), size_t{7});
  CHECK_EQ(a.back(), 50000u);
  for (size_t i = 0; i + 1 < a.size(); ++i) CHECK(a[i] >= (i + 1) * ota::kWindow && a[i] < (i + 1) * ota::kWindow + 240);
  CHECK_EQ(r.flash.boot, 0);  // nothing switched yet
  const Bytes e = r.control(kEnd);
  CHECK_EQ(e.size(), size_t{1});
  CHECK_EQ(e[0], ota::kEndOk);
  CHECK(r.flash.slot[1] == img);
  CHECK_EQ(r.flash.boot, 1);
  CHECK_EQ(r.restarts, 1);
  CHECK(r.rx.restarting());
  CHECK(r.isActive);  // stays busy until the restart
  CHECK(isError(r.control(beginMsg(img, 3, 9, 0)), ota::Error::Busy));
}

TEST(ota_resume_after_a_dropout_mid_window) {
  OtaRig r;
  const Bytes img = makeImage(40000);
  r.control(beginMsg(img, 3, 9, 0));
  r.send(img, 0, 20000);  // 20000 is mid-window
  // The phone went away; later the same image comes back within the timeout.
  r.now += 5000;
  CHECK_EQ(beginStart(r.control(beginMsg(img, 3, 9, 0))), 20000u);
  CHECK_EQ(r.flash.begins, 1);
  // …or after it: the transfer stopped, what arrived is kept for this boot.
  r.now += ota::kTimeoutMs;
  r.replies.clear();
  r.rx.tick(r.now);
  CHECK(isError(r.replies.back(), ota::Error::Timeout));
  CHECK(!r.isActive && !r.rx.active());
  CHECK(r.rx.canResume());
  CHECK_EQ(beginStart(r.control(beginMsg(img, 3, 9, 0))), 20000u);
  CHECK_EQ(r.flash.resumes, 1);
  r.send(img, 20000, 40000);
  CHECK_EQ(r.control(kEnd)[0], ota::kEndOk);
  CHECK(r.flash.slot[1] == img);
}

TEST(ota_other_image_after_timeout_starts_over) {
  OtaRig r;
  const Bytes img = makeImage(30000);
  r.control(beginMsg(img, 3, 9, 0));
  r.send(img, 0, 10000);
  r.now += ota::kTimeoutMs;
  r.rx.tick(r.now);
  const Bytes other = makeImage(30000, "3.9.1");
  CHECK_EQ(beginStart(r.control(beginMsg(other, 3, 9, 1))), 0u);
  CHECK_EQ(r.flash.begins, 2);
  CHECK(!r.rx.canResume());
}

TEST(ota_duplicates_and_gaps_are_ignored_with_one_ack) {
  OtaRig r;
  const Bytes img = makeImage(20000);
  r.control(beginMsg(img, 3, 9, 0));
  r.send(img, 0, 1200);
  r.replies.clear();
  r.data(dataMsg(img, 480, 240));  // duplicate
  r.data(dataMsg(img, 480, 240));  // again: no second ACK
  r.data(dataMsg(img, 2400, 240)); // a gap: still the same stretch
  CHECK(acks(r.replies) == std::vector<uint32_t>{1200});
  r.send(img, 1200, 2400);          // back in order
  r.replies.clear();
  r.data(dataMsg(img, 4800, 240));  // a new gap: a new ACK
  CHECK(acks(r.replies) == std::vector<uint32_t>{2400});
  CHECK_EQ(r.rx.next(), 2400u);
  CHECK_EQ(r.rx.ignoredChunks(), 4u);
  r.send(img, 2400, 20000);
  CHECK_EQ(r.control(kEnd)[0], ota::kEndOk);
  CHECK(r.flash.slot[1] == img);
}

TEST(ota_status_reports_progress) {
  OtaRig r;
  Bytes s = r.control(kStatus);
  CHECK(s.size() == 10 && s[0] == ota::kState && s[1] == ota::kStateIdle);
  const Bytes img = makeImage(9000);
  r.control(beginMsg(img, 3, 9, 0));
  r.send(img, 0, 1000);
  s = r.control(kStatus);
  CHECK(s[1] == ota::kStateReceiving && getU32(&s[2]) == 1000u && getU32(&s[6]) == 9000u);
}

TEST(ota_end_checks_count_hash_image_and_identity) {
  {  // too early: the transfer goes on
    OtaRig r;
    const Bytes img = makeImage(9000);
    r.control(beginMsg(img, 3, 9, 0));
    r.send(img, 0, 5000);
    const Bytes e = r.control(kEnd);
    CHECK(e.size() == 6 && e[0] == ota::kError && e[1] == uint8_t(ota::Error::Incomplete) && getU32(&e[2]) == 5000u);
    CHECK(r.rx.active());
  }
  {  // hash mismatch: discarded, nothing switched
    OtaRig r;
    const Bytes img = makeImage(9000);
    uint8_t wrong[32] = {1};
    r.control(beginMsg(img, 3, 9, 0, false, wrong));
    r.send(img, 0, 9000);
    CHECK(isError(r.control(kEnd), ota::Error::HashMismatch));
    CHECK(!r.rx.active() && !r.isActive && !r.rx.canResume());
    CHECK_EQ(r.flash.boot, 0);
  }
  {  // not a valid app image (esp_ota_end)
    OtaRig r;
    Bytes img = makeImage(9000);
    img[0] = 0x00;
    r.control(beginMsg(img, 3, 9, 0));
    r.send(img, 0, 9000);
    CHECK(isError(r.control(kEnd), ota::Error::NotElectroBright));
    CHECK_EQ(r.flash.boot, 0);
  }
  // A valid image without an ElectroBright universal identity of that version.
  for (const Bytes& img : {makeImage(9000, "3.9.0", "Espressif"), makeImage(9000, "3.9.0", "ElectroBright", "rgbw"),
                           makeImage(9000, "3.9.1"), makeImage(9000, "3.9.0", "ElectroBright", "universal", false)}) {
    OtaRig r;
    r.control(beginMsg(img, 3, 9, 0));
    r.send(img, 0, static_cast<uint32_t>(img.size()));
    CHECK(isError(r.control(kEnd), ota::Error::NotElectroBright));
    CHECK_EQ(r.flash.boot, 0);
    CHECK_EQ(r.restarts, 0);
  }
  {  // the boot selection cannot be written
    OtaRig r;
    const Bytes img = makeImage(9000);
    r.flash.failSetBoot = true;
    r.control(beginMsg(img, 3, 9, 0));
    r.send(img, 0, 9000);
    CHECK(isError(r.control(kEnd), ota::Error::FlashError));
    CHECK_EQ(r.restarts, 0);
  }
}

TEST(ota_begin_rules_size_version_reinstall_busy) {
  OtaRig r;
  const Bytes img = makeImage(9000);
  CHECK(isError(r.control(beginMsg(makeImage(0), 3, 9, 0)), ota::Error::BadSize));
  r.flash.capacity = 8000;
  CHECK(isError(r.control(beginMsg(img, 3, 9, 0)), ota::Error::BadSize));
  r.flash.capacity = 0x140000;
  CHECK(isError(r.control(beginMsg(img, 3, 7, 9)), ota::Error::Downgrade));
  CHECK(isError(r.control(beginMsg(img, 2, 99, 99)), ota::Error::Downgrade));
  CHECK(isError(r.control(beginMsg(img, 3, 8, 0)), ota::Error::SameVersion));
  CHECK_EQ(beginStart(r.control(beginMsg(makeImage(9000, "3.8.0"), 3, 8, 0, true))), 0u);  // reinstall
  // Another image while one is receiving: busy; ABORT frees it.
  CHECK(isError(r.control(beginMsg(img, 3, 9, 0)), ota::Error::Busy));
  CHECK_EQ(r.control(kAbort)[0], ota::kAborted);
  CHECK_EQ(beginStart(r.control(beginMsg(img, 3, 9, 0))), 0u);
  // Malformed requests say so.
  CHECK(isError(r.control(Bytes{ota::kBegin, 1, 2}), ota::Error::BadRequest));
  CHECK(isError(r.control(Bytes{0x7F}), ota::Error::BadRequest));
  CHECK(isError(r.control(Bytes{ota::kEnd, 0}), ota::Error::BadRequest));
  // The new firmware is not confirmed yet (rollback pending): busy.
  OtaRig p;
  p.flash.state[0] = MockOtaFlash::SlotState::PendingVerify;
  CHECK(isError(p.control(beginMsg(img, 3, 9, 0)), ota::Error::Busy));
  CHECK(!p.isActive);
  // A SET_TYPE restart is pending: busy.
  OtaRig q;
  q.rx.setBlocked(true);
  CHECK(isError(q.control(beginMsg(img, 3, 9, 0)), ota::Error::Busy));
}

TEST(ota_abort_timeout_and_flash_errors_leave_the_running_firmware) {
  OtaRig r;
  const Bytes img = makeImage(30000);
  r.control(beginMsg(img, 3, 9, 0));
  r.send(img, 0, 9000);
  CHECK_EQ(r.control(kAbort)[0], ota::kAborted);
  CHECK(!r.rx.active() && !r.isActive && !r.rx.canResume());
  CHECK_EQ(r.flash.boot, 0);
  CHECK_EQ(r.control(kAbort)[0], ota::kAborted);  // idempotent
  CHECK(isError(r.control(kEnd), ota::Error::BadRequest));
  // DATA without a transfer: ignored.
  r.data(dataMsg(img, 0, 240));
  CHECK_EQ(r.rx.next(), 0u);
  // Timeout: no data for 15 s.
  r.control(beginMsg(img, 3, 9, 0));
  r.now += ota::kTimeoutMs - 1;
  r.rx.tick(r.now);
  CHECK(r.rx.active());
  r.now += 1;
  r.rx.tick(r.now);
  CHECK(!r.rx.active() && !r.isActive);
  // A flash write failure: explicit, discarded.
  r.control(kAbort);
  r.control(beginMsg(img, 3, 9, 0));
  r.flash.failWrites = true;
  r.replies.clear();
  r.data(dataMsg(img, 0, 240));
  CHECK(isError(r.replies.back(), ota::Error::FlashError));
  CHECK(!r.rx.active() && !r.rx.canResume());
  r.flash.failWrites = false;
  r.flash.failBegin = true;
  CHECK(isError(r.control(beginMsg(img, 3, 9, 0)), ota::Error::FlashError));
  // A chunk past the end.
  r.flash.failBegin = false;
  const Bytes small = makeImage(1000);
  r.control(beginMsg(small, 3, 9, 0));
  r.replies.clear();
  r.data(dataMsg(img, 0, 1200));
  CHECK(isError(r.replies.back(), ota::Error::BadSize));
  CHECK_EQ(r.flash.boot, 0);
}

// ---- The light during a transfer ------------------------------------------------------------

TEST(ota_light_is_busy_during_a_transfer) {
  Rig r;
  r.send("PROBE:1:1");
  r.send("IDENTIFY");
  r.core.setOtaBusy(true);
  CHECK_EQ(r.env.params.ota, 1);
  CHECK_EQ(r.env.params.probe, 0);
  CHECK_EQ(r.env.params.identifyId, 0);
  for (const char* cmd : {"MODE:2", "COLOR:1,2,3,4", "PRESET_SAVE:1", "SET_TYPE:CCT", "PROBE:1:1", "IDENTIFY",
                          "FACTORY_RESET", "SLEEP", "TIMER:5"}) {
    r.env.clear();
    r.send(cmd);
    CHECK_STR(r.env.last(), "ERROR:BUSY");
  }
  for (const char* q : {"STATUS", "VERSION", "CAPS", "DIAG", "PING", "PRESET_LIST"}) {
    r.env.clear();
    r.send(q);
    CHECK(r.env.last().rfind("ERROR", 0) != 0);
  }
  const Color8 before = r.core.scene().color;
  ColorFrame f{};
  f.color = {1, 2, 3, 4};
  r.core.onColorFrame(f, r.now);
  CHECK(r.core.scene().color == before);
  r.core.setOtaBusy(false);
  CHECK_EQ(r.env.params.ota, 0);
  r.send("MODE:2");
  CHECK_STR(r.env.last(), "OK");
}

TEST(ota_glow_uses_the_white_leds) {
  CHECK_EQ(otaglow::channels(profiles::kRgbw), 0x08);    // W
  CHECK_EQ(otaglow::channels(profiles::kRgb), 0x07);     // R, G, B
  CHECK_EQ(otaglow::channels(profiles::kRgbcct), 0x18);  // CW, WW
  CHECK_EQ(otaglow::channels(profiles::kCct), 0x03);     // CW, WW
  CHECK_EQ(otaglow::channels(profiles::kW), 0x01);
  CHECK_EQ(otaglow::channels(profiles::kNone), 0x00);    // setup needed: all off
  CHECK(otaglow::kLowCounts < otaglow::kHighCounts);
}

// ---- End to end on the simulated light (fwsim) ---------------------------------------------

namespace {

void link(SimDevice& d) {
  d.connect();
  d.setMtu(517);
  d.setSubscribed(true);
  d.setOtaSubscribed(true);
  d.pass();
  d.takeNotifications();
  d.takeOtaNotifications();
}

std::vector<Bytes> control(SimDevice& d, const Bytes& m) {
  d.otaControl(m.data(), m.size());
  d.pass();
  return d.takeOtaNotifications();
}

// The app's side: one window at a time, continuing wherever an ACK says.
bool transfer(SimDevice& d, const Bytes& img, uint32_t from, size_t chunk = 500) {
  uint32_t next = from;
  for (int rounds = 0; rounds < 1000 && next < img.size(); ++rounds) {
    const uint32_t windowEnd =
        static_cast<uint32_t>(std::min<size_t>(img.size(), (next / ota::kWindow + 1) * ota::kWindow));
    for (uint32_t off = next; off < windowEnd;) {
      const size_t n = std::min<size_t>(chunk, windowEnd - off);
      const Bytes m = dataMsg(img, off, n);
      d.otaData(m.data(), m.size());
      off += static_cast<uint32_t>(n);
    }
    d.pass();
    for (const Bytes& r : d.takeOtaNotifications()) {
      if (r.size() == 5 && r[0] == ota::kAck) next = getU32(&r[1]);
    }
  }
  return next == img.size();
}

}  // namespace

TEST(ota_fwsim_update_restarts_into_the_new_slot_and_confirms) {
  SimDevice d(FixtureType::Cct);
  d.boot();
  link(d);
  const Bytes img = makeImage(100000, "3.9.0");
  CHECK_EQ(beginStart(control(d, beginMsg(img, 3, 9, 0)).at(0)), 0u);
  CHECK(d.ota().active() && d.core().otaBusy() && d.fastLink());
  CHECK(transfer(d, img, 0));
  const std::vector<Bytes> end = control(d, kEnd);
  CHECK(end.size() == 1 && end[0][0] == ota::kEndOk);  // delivered before the restart
  CHECK_EQ(d.restarts(), 1);
  CHECK(!d.connected());
  CHECK_EQ(d.otaFlash().running, 1);
  CHECK(d.otaFlash().pendingVerify());
  CHECK(d.selfChecking());
  CHECK(d.systemFlash().data.count("ofx") == 1);  // the type the new firmware must load
  // The new firmware comes up, keeps its type and confirms itself.
  d.advance(3000);
  CHECK(!d.selfChecking());
  CHECK(!d.otaFlash().pendingVerify());
  CHECK(d.systemFlash().data.count("ofx") == 0);
  CHECK(&d.fixture() == &profiles::kCct);
  // A later power cycle stays on it.
  d.reboot();
  CHECK_EQ(d.otaFlash().running, 1);
  link(d);
  const char diag[] = "DIAG\n";
  d.write(reinterpret_cast<const uint8_t*>(diag), 5);
  d.pass();
  std::string text;
  for (const auto& n : d.takeNotifications()) text.append(n.begin(), n.end());
  CHECK(text.find(",slot=1,rb=0") != std::string::npos);
}

TEST(ota_fwsim_crash_before_confirming_rolls_back) {
  SimDevice d;
  d.boot();
  link(d);
  const Bytes img = makeImage(20000);
  control(d, beginMsg(img, 3, 9, 0));
  CHECK(transfer(d, img, 0));
  control(d, kEnd);
  CHECK_EQ(d.otaFlash().running, 1);
  // It crashes (or the task watchdog resets it) before the self-check passed.
  d.advance(500);
  d.reboot();
  CHECK_EQ(d.otaFlash().running, 0);
  CHECK(d.otaFlash().rolledBack());
  CHECK(!d.selfChecking());
  link(d);
  const char diag[] = "DIAG\n";
  d.write(reinterpret_cast<const uint8_t*>(diag), 5);
  d.pass();
  std::string text;
  for (const auto& n : d.takeNotifications()) text.append(n.begin(), n.end());
  CHECK(text.find(",slot=0,rb=1") != std::string::npos);
}

TEST(ota_fwsim_failed_self_check_rolls_back) {
  SimDevice d(FixtureType::Rgbcct);
  d.boot();
  link(d);
  const Bytes img = makeImage(20000);
  control(d, beginMsg(img, 3, 9, 0));
  CHECK(transfer(d, img, 0));
  control(d, kEnd);
  CHECK(d.selfChecking());
  // The new firmware came up with another type than the light had: the check
  // never passes, and after 15 s it returns to the previous firmware.
  d.systemFlash().data["ofx"] = {static_cast<uint8_t>(FixtureType::W)};
  d.advance(selfcheck::kDeadlineMs - 100);
  CHECK_EQ(d.otaFlash().running, 1);
  d.advance(200);
  CHECK_EQ(d.otaFlash().running, 0);
  CHECK(d.otaFlash().rolledBack());
  CHECK_EQ(d.restarts(), 2);
}

TEST(ota_self_check_verdicts) {
  const selfcheck::Inputs ok{true, true, selfcheck::kMinRenderFrames, true};
  CHECK(selfcheck::evaluate(ok, 2000) == selfcheck::Verdict::Pass);
  selfcheck::Inputs slow = ok;
  slow.renderFrames = 10;
  CHECK(selfcheck::evaluate(slow, 2000) == selfcheck::Verdict::Pending);
  CHECK(selfcheck::evaluate(slow, selfcheck::kDeadlineMs) == selfcheck::Verdict::Fail);
  for (int i = 0; i < 3; ++i) {
    selfcheck::Inputs bad = ok;
    (i == 0 ? bad.nvsReadable : i == 1 ? bad.typeLoaded : bad.bleUp) = false;
    CHECK(selfcheck::evaluate(bad, 14999) == selfcheck::Verdict::Pending);
    CHECK(selfcheck::evaluate(bad, 15000) == selfcheck::Verdict::Fail);
  }
  // The type check: nothing to compare without an update marker.
  MockKv sys;
  CHECK(fxselect::typeLoaded(sys, FixtureType::None));
  CHECK(fxselect::rememberForUpdate(sys, FixtureType::Cct));
  CHECK(fxselect::typeLoaded(sys, FixtureType::Cct));
  CHECK(!fxselect::typeLoaded(sys, FixtureType::Rgbw));
  CHECK(fxselect::forgetUpdate(sys));
  CHECK(fxselect::typeLoaded(sys, FixtureType::Rgbw));
}

TEST(ota_fwsim_dropout_mid_window_resumes_after_reconnect) {
  SimDevice d;
  d.boot();
  link(d);
  const Bytes img = makeImage(60000);
  control(d, beginMsg(img, 3, 9, 0));
  // Two windows and part of a third arrive, then the link drops (the rest of
  // the window is lost in the air).
  for (uint32_t off = 0; off < 20000; off += 500) {
    const Bytes m = dataMsg(img, off, std::min<uint32_t>(500, 20000 - off));
    d.otaData(m.data(), m.size());
    if (off % 4000 == 3500) d.pass();  // the light keeps up with the app
  }
  d.pass();
  d.disconnect();
  d.pass();
  CHECK(d.ota().active());  // waiting for the app to come back
  d.advance(4000);
  link(d);
  const std::vector<Bytes> b = control(d, beginMsg(img, 3, 9, 0));
  CHECK_EQ(beginStart(b.at(0)), 20000u);
  CHECK(transfer(d, img, 20000));
  CHECK_EQ(control(d, kEnd).at(0)[0], ota::kEndOk);
  CHECK(d.otaFlash().slot[1] == img);
}

TEST(ota_fwsim_overflowing_writes_are_recovered_by_ack) {
  SimDevice d;
  d.boot();
  link(d);
  const Bytes img = makeImage(40000);
  control(d, beginMsg(img, 3, 9, 0));
  // An app that ignores the window: most of this cannot be buffered.
  for (uint32_t off = 0; off < 40000; off += 500) {
    const Bytes m = dataMsg(img, off, 500);
    d.otaData(m.data(), m.size());
  }
  d.pass();
  uint32_t next = 0;
  for (const Bytes& r : d.takeOtaNotifications()) {
    if (r[0] == ota::kAck) next = getU32(&r[1]);
  }
  CHECK(next > 0 && next < 40000u);
  CHECK(transfer(d, img, next));
  CHECK_EQ(control(d, kEnd).at(0)[0], ota::kEndOk);
}
