import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../sessions/connection_manager.dart';
import 'platform_api.g.dart';

export 'platform_api.g.dart' show BluetoothAuthorization, SettingsPage;

/// Native services (Swift/Kotlin hosts). Every call degrades gracefully when
/// the host is missing (widget tests, unsupported platforms).
final class PlatformBridge implements BackgroundTasks, PlatformEventsApi {
  PlatformBridge({PlatformHostApi? api}) : _api = api ?? PlatformHostApi() {
    try {
      PlatformEventsApi.setUp(this);
    } on Object {
      // No binding in plain unit tests.
    }
  }

  final PlatformHostApi _api;

  /// Reduce Transparency (iOS); glass surfaces become solid while true.
  final ValueNotifier<bool> reduceTransparency = ValueNotifier<bool>(false);

  /// Called when the OS is about to end a background task.
  void Function(int id)? onTaskExpiring;

  Future<void> init() async {
    reduceTransparency.value = await _safe(_api.reduceTransparency, false);
  }

  Future<BluetoothAuthorization> authorization() =>
      _safe(_api.bluetoothAuthorization, BluetoothAuthorization.allowed);

  Future<BluetoothAuthorization> requestAuthorization() =>
      _safe(_api.requestBluetoothAuthorization, BluetoothAuthorization.allowed);

  Future<bool> requestEnableBluetooth() =>
      _safe(_api.requestEnableBluetooth, false);

  Future<bool> locationServicesRequiredButOff() =>
      _safe(_api.locationServicesRequiredButOff, false);

  Future<void> openSettings(SettingsPage page) =>
      _safe(() => _api.openSettings(page), null);

  Future<DisplayInfo> displayInfo() =>
      _safe(_api.displayInfo, DisplayInfo(refreshRate: 60, maxRefreshRate: 60));

  @override
  Future<int> begin(String name) =>
      _safe(() => _api.beginBackgroundTask(name), -1);

  @override
  Future<void> end(int id) => _safe(() => _api.endBackgroundTask(id), null);

  @override
  void onReduceTransparencyChanged(bool enabled) =>
      reduceTransparency.value = enabled;

  @override
  void onBackgroundTaskExpiring(int id) => onTaskExpiring?.call(id);

  static Future<T> _safe<T>(Future<T> Function() call, T fallback) async {
    try {
      return await call();
    } on Object {
      return fallback;
    }
  }
}
