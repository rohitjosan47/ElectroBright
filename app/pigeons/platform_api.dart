// Native bridge definition. Regenerate with:
//   dart run pigeon --input pigeons/platform_api.dart
// Generated files are checked in; never edit them by hand.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/design/platform/platform_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/com/electrobright/electrobright_app/PlatformApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.electrobright.electrobright_app'),
    swiftOut: 'ios/Runner/PlatformApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'electrobright',
  ),
)
/// Semantic haptic events. Each platform maps an event to its best native
/// rendering (see HapticsHost.swift / HapticsHost.kt).
enum HapticEvent {
  /// Tab, segment or mode-tile snap.
  selection,

  /// 10 % slider step or dial detent.
  detent,

  /// Slider end stop (0 % / 100 %).
  edge,

  /// Colour wheel passing a 30° hue mark.
  hueDetent,

  /// Colour wheel passing a primary hue (red, green, blue).
  hueDetentStrong,
  powerOn,
  powerOff,
  success,
  warning,
  error,
  presetLoaded,
  connected,
  longPress,
}

@HostApi()
abstract class HapticsHostApi {
  /// Warms the haptic engine for an imminent gesture (call on touch-down).
  void prepare(HapticEvent event);

  /// Plays [event] at [intensity] (0..1, already scaled by the user setting).
  void play(HapticEvent event, double intensity);
}

enum BluetoothAuthorization {
  /// The user has not been asked yet.
  notDetermined,

  /// Blocked by the system (parental controls / MDM).
  restricted,
  denied,
  allowed,

  /// The device has no Bluetooth LE.
  unsupported,
}

enum SettingsPage { app, bluetooth, location }

class DisplayInfo {
  DisplayInfo({required this.refreshRate, required this.maxRefreshRate});
  double refreshRate;
  double maxRefreshRate;
}

@HostApi()
abstract class PlatformHostApi {
  /// Current Bluetooth permission, read WITHOUT showing any system prompt.
  BluetoothAuthorization bluetoothAuthorization();

  /// Shows the system permission prompt when the state is notDetermined and
  /// returns the result (iOS: via a short-lived CBCentralManager).
  @async
  BluetoothAuthorization requestBluetoothAuthorization();

  /// Android: asks the user to switch Bluetooth on (system dialog).
  /// iOS: not possible; returns false.
  @async
  bool requestEnableBluetooth();

  /// Android 11 and older need Location Services on to scan for BLE devices.
  bool locationServicesRequiredButOff();

  /// Opens a system settings page (iOS always opens the app's page).
  void openSettings(SettingsPage page);

  /// iOS "Reduce Transparency"; Android has no equivalent (false).
  bool reduceTransparency();

  /// iOS: UIApplication.beginBackgroundTask; returns -1 when unsupported.
  int beginBackgroundTask(String name);
  void endBackgroundTask(int id);

  DisplayInfo displayInfo();

  /// Android: asks for the display's highest refresh rate while [high]
  /// (something moves or a finger is down); otherwise leaves the rate to
  /// the system. iOS: nothing (ProMotion adapts on its own).
  void setHighRefreshRate(bool high);

  /// Keeps the screen on while [on] (a firmware transfer runs): iOS
  /// UIApplication.isIdleTimerDisabled, Android FLAG_KEEP_SCREEN_ON.
  void setKeepAwake(bool on);
}

@FlutterApi()
abstract class PlatformEventsApi {
  void onReduceTransparencyChanged(bool enabled);

  /// The OS is about to end background task [id]; clean up immediately.
  void onBackgroundTaskExpiring(int id);
}
