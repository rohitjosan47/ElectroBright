#pragma once
// Receives a wireless update (OtaProtocol.h) into the spare app slot and
// switches to it only when every check has passed: byte count, SHA-256,
// esp_ota_end's image validation and the identity block (ImageIdentity.h).
// Until then the running firmware and its boot selection are untouched.
//
// Owned by the control task (like ControllerCore): no locking. Portable.
//
// A transfer stops on ABORT, on any failed check, and after
// ota::kTimeoutMs without data. A timeout keeps what was received: a BEGIN of
// the same image (same size, hash and version) in the same boot continues
// from there. ABORT and a failed check forget it.

#include <stddef.h>
#include <stdint.h>

#include "ImageIdentity.h"
#include "OtaFlash.h"
#include "OtaProtocol.h"
#include "Sha256.h"

class IOtaEnv {
 public:
  // One reply notification on the control characteristic.
  virtual void otaReply(const uint8_t* data, size_t len) = 0;
  // A transfer started (true) or stopped (false): the light refuses normal
  // commands as busy and shows its update glow meanwhile.
  virtual void otaActive(bool active) = 0;
  // The new firmware is selected: restart once the reply has gone out.
  virtual void otaRestart() = 0;

 protected:
  ~IOtaEnv() = default;
};

class OtaReceiver {
 public:
  OtaReceiver(IOtaFlash& flash, IOtaEnv& env, const FirmwareVersion& running)
      : flash_(flash), env_(env), running_(running) {}

  void onControl(const uint8_t* data, size_t len, uint32_t nowMs);
  void onData(const uint8_t* data, size_t len, uint32_t nowMs);
  // Timeout; call at least every ~100 ms.
  void tick(uint32_t nowMs);

  // While blocked (a SET_TYPE restart is pending) BEGIN is refused as busy.
  void setBlocked(bool blocked) { blocked_ = blocked; }

  bool active() const { return active_; }
  bool restarting() const { return restarting_; }
  uint32_t next() const { return active_ ? next_ : 0; }
  uint32_t size() const { return active_ ? image_.size : 0; }
  bool canResume() const { return resume_.valid; }
  uint32_t ignoredChunks() const { return ignored_; }

 private:
  struct Image {
    uint32_t size = 0;
    uint8_t hash[Sha256::kDigestSize] = {};
    FirmwareVersion version{};
    bool same(const Image& o) const;
  };
  struct ResumePoint {
    bool valid = false;
    Image image;
    uint32_t next = 0;
    Sha256 sha;
  };

  void begin(const uint8_t* d, size_t len, uint32_t nowMs);
  void end();
  void abortTransfer();
  void stop(bool keepResume);
  void replyError(ota::Error code);
  void replyAck();
  void replyState();

  IOtaFlash& flash_;
  IOtaEnv& env_;
  const FirmwareVersion running_;

  bool active_ = false;
  bool restarting_ = false;
  bool blocked_ = false;
  Image image_;
  uint32_t next_ = 0;
  Sha256 sha_;
  uint32_t lastDataMs_ = 0;
  bool outOfOrderReported_ = false;  // one ACK per stretch of ignored chunks
  ResumePoint resume_;
  uint32_t ignored_ = 0;
  uint8_t head_[imageid::kSearchBytes];  // the image head read back at END (off the task stack)
};
