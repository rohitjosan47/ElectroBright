/// Constants matching the ESP32-C3 firmware protocol (v2.6.0).
class BleConstants {
  // Rate Limiting & Coalescing
  static const int continuousThrottleMs = 40; // ~25Hz transmission rate for smooth slider drag
  static const int echoSuppressionGraceMs = 250; // Grace window to prevent rubber-banding
}
