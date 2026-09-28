import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ble/ble_central.dart';
import '../design/platform/platform_bridge.dart';
import 'app_session.dart';

/// Why the app can't use Bluetooth right now, as the user is told.
enum BluetoothIssue {
  /// Bluetooth is switched off.
  off,

  /// The user has not allowed Bluetooth for the app.
  denied,

  /// No Bluetooth LE on this phone.
  unsupported,

  /// Android 11 and older: scanning also needs Location Services.
  locationOff,
}

/// The issue behind [s] (none while ready or not yet known).
BluetoothIssue? bluetoothIssueOf(BleAdapterState s) => switch (s) {
  BleAdapterState.poweredOff => BluetoothIssue.off,
  BleAdapterState.unauthorized => BluetoothIssue.denied,
  BleAdapterState.unsupported => BluetoothIssue.unsupported,
  BleAdapterState.locationServicesDisabled => BluetoothIssue.locationOff,
  BleAdapterState.unknown || BleAdapterState.ready => null,
};

/// What the app needs from the phone before it can use real lights.
///
/// Android: the runtime permissions (BLUETOOTH_SCAN and BLUETOOTH_CONNECT
/// on 12+, location on 11 and older), then Bluetooth switched on, and on 11
/// and older Location Services. They are asked for on "Use my lights" and
/// whenever the radio reports the app unauthorized. iOS asks on its own
/// when the Bluetooth stack starts, so nothing is requested there.
final class BluetoothAccess {
  BluetoothAccess({
    required this._platform,
    required BleCentral central,
    bool? android,
  }) : android = android ?? defaultTargetPlatform == TargetPlatform.android {
    _sub = central.adapterState.listen(_onAdapter);
  }

  final PlatformBridge _platform;
  final bool android;
  late final StreamSubscription<BleAdapterState> _sub;
  BleAdapterState _last = BleAdapterState.unknown;
  Future<void>? _asking;

  /// Android 11 and older: Location Services are off, so scans find
  /// nothing (the radio may still report ready).
  final ValueNotifier<bool> locationOff = ValueNotifier<bool>(false);

  void _onAdapter(BleAdapterState s) {
    final BleAdapterState before = _last;
    _last = s;
    if (s == BleAdapterState.unauthorized &&
        before != BleAdapterState.unauthorized) {
      unawaited(ensure());
    }
    unawaited(checkLocation());
  }

  /// Asks for what is missing: the permission, then (only when it is off)
  /// switching Bluetooth on. One request at a time.
  Future<void> ensure() =>
      _asking ??= _ask().whenComplete(() => _asking = null);

  Future<void> _ask() async {
    if (!android) return;
    BluetoothAuthorization a = await _platform.authorization();
    // Asked before and refused: Android shows the prompt again until the
    // user picks "Don't ask again", then answers at once (Settings remains).
    if (a == BluetoothAuthorization.notDetermined ||
        a == BluetoothAuthorization.denied) {
      a = await _platform.requestAuthorization();
    }
    if (a != BluetoothAuthorization.allowed) return;
    await checkLocation();
    // Shows the system dialog only while Bluetooth is off.
    await _platform.requestEnableBluetooth();
  }

  /// Reads Location Services again (start, adapter changes, app resumed).
  Future<void> checkLocation() async {
    if (!android) return;
    locationOff.value = await _platform.locationServicesRequiredButOff();
  }

  /// The notice's action for [issue] (see [BluetoothIssueAction]).
  Future<void> resolve(BluetoothIssue issue) async {
    switch (actionFor(issue, android: android)) {
      case BluetoothIssueAction.turnOn:
        await _platform.requestEnableBluetooth();
      case BluetoothIssueAction.openSettings:
        await _platform.openSettings(
          issue == BluetoothIssue.locationOff
              ? SettingsPage.location
              : SettingsPage.app,
        );
      case null:
        break;
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    locationOff.dispose();
  }
}

/// What the user can do about an issue from the app.
enum BluetoothIssueAction { turnOn, openSettings }

/// Android switches Bluetooth on from a system dialog; iOS can't (the text
/// points to Control Centre). A refused permission and Location Services are
/// changed in Settings; an unsupported phone has nothing to do.
BluetoothIssueAction? actionFor(
  BluetoothIssue issue, {
  required bool android,
}) => switch (issue) {
  BluetoothIssue.off => android ? BluetoothIssueAction.turnOn : null,
  BluetoothIssue.denied ||
  BluetoothIssue.locationOff => BluetoothIssueAction.openSettings,
  BluetoothIssue.unsupported => null,
};

/// The radio's state as the user is told: Location Services off (Android 11
/// and older) shows even while the radio says ready.
final NotifierProvider<BluetoothStateNotifier, BleAdapterState>
bluetoothStateProvider =
    NotifierProvider<BluetoothStateNotifier, BleAdapterState>(
      BluetoothStateNotifier.new,
    );

final class BluetoothStateNotifier extends Notifier<BleAdapterState> {
  @override
  BleAdapterState build() {
    final AppSession? app = ref.watch(appSessionProvider);
    if (app == null) return BleAdapterState.unknown;
    final BluetoothAccess? access = app.bluetooth;
    BleAdapterState radio = app.ble.central.currentAdapterState;
    BleAdapterState shown() =>
        radio == BleAdapterState.ready && (access?.locationOff.value ?? false)
        ? BleAdapterState.locationServicesDisabled
        : radio;
    final StreamSubscription<BleAdapterState> sub = app.ble.central.adapterState
        .listen((BleAdapterState s) {
          radio = s;
          state = shown();
        });
    void onLocation() => state = shown();
    access?.locationOff.addListener(onLocation);
    ref.onDispose(() {
      unawaited(sub.cancel());
      access?.locationOff.removeListener(onLocation);
    });
    return shown();
  }
}

/// Why Bluetooth can't be used right now (null: it can, or not known yet).
final Provider<BluetoothIssue?> bluetoothIssueProvider =
    Provider<BluetoothIssue?>(
      (Ref ref) => bluetoothIssueOf(ref.watch(bluetoothStateProvider)),
    );
