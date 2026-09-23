/// Constants matching the ESP32-C3 firmware protocol (v2.9.0).
class BleConstants {
  // Rate Limiting & Coalescing
  static const int continuousThrottleMs = 30; // ~33Hz max transmission rate for continuous slider/wheel drags
  static const int echoSuppressionGraceMs = 250; // Grace window to prevent rubber-banding
  static const int toggleSuppressionMs = 1500; // Hold after a discrete toggle (power, sound) until the device confirms
}
