import 'package:flutter/services.dart';

/// Centralized tactile feedback service.
class HapticService {
  static void lightTick() {
    HapticFeedback.lightImpact();
  }

  static void selectionTick() {
    HapticFeedback.selectionClick();
  }

  static void pop() {
    HapticFeedback.mediumImpact();
  }

  static void alert() {
    HapticFeedback.heavyImpact();
  }
}
