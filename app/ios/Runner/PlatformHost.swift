import CoreBluetooth
import Flutter
import UIKit

/// Native services for Dart (pigeons/platform_api.dart): Bluetooth permission
/// without touching the BLE plugin, settings links, Reduce Transparency and
/// background tasks.
final class PlatformHost: NSObject, PlatformHostApi {
  private let events: PlatformEventsApi
  private var permissionProbe: BluetoothPermissionProbe?

  init(messenger: FlutterBinaryMessenger) {
    events = PlatformEventsApi(binaryMessenger: messenger)
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reduceTransparencyChanged),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: Bluetooth permission

  func bluetoothAuthorization() throws -> BluetoothAuthorization {
    Self.map(CBManager.authorization)
  }

  func requestBluetoothAuthorization() async throws -> BluetoothAuthorization {
    if CBManager.authorization != .notDetermined {
      return Self.map(CBManager.authorization)
    }
    // Creating a central manager shows the system prompt; its first state
    // update after the user answers resolves the request. The BLE plugin is
    // only initialised after this, so the prompt appears exactly here.
    return await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        self.permissionProbe = BluetoothPermissionProbe { [weak self] in
          self?.permissionProbe = nil
          continuation.resume(returning: Self.map(CBManager.authorization))
        }
      }
    }
  }

  func requestEnableBluetooth() async throws -> Bool {
    false  // iOS offers no API to switch Bluetooth on; the UI explains how.
  }

  func locationServicesRequiredButOff() throws -> Bool {
    false  // iOS scans without Location Services.
  }

  private static func map(_ authorization: CBManagerAuthorization) -> BluetoothAuthorization {
    switch authorization {
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    case .denied: return .denied
    case .allowedAlways: return .allowed
    @unknown default: return .denied
    }
  }

  // MARK: Settings, accessibility, display

  func openSettings(page: SettingsPage) throws {
    // iOS only allows deep links to the app's own settings page.
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    DispatchQueue.main.async { UIApplication.shared.open(url) }
  }

  func reduceTransparency() throws -> Bool {
    UIAccessibility.isReduceTransparencyEnabled
  }

  @objc private func reduceTransparencyChanged() {
    let enabled = UIAccessibility.isReduceTransparencyEnabled
    Task { @MainActor in try? await self.events.onReduceTransparencyChanged(enabled: enabled) }
  }

  func displayInfo() throws -> DisplayInfo {
    let screen = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen }
      .first
    let maxFps = Double(screen?.maximumFramesPerSecond ?? 60)
    // ProMotion adapts the rate on the fly; report the ceiling for both.
    return DisplayInfo(refreshRate: maxFps, maxRefreshRate: maxFps)
  }

  // ProMotion adapts the rate on its own (the engine's display link asks
  // for up to the display's maximum only while frames are drawn).
  func setHighRefreshRate(high: Bool) throws {}

  // MARK: Background tasks

  func beginBackgroundTask(name: String) throws -> Int64 {
    var id: UIBackgroundTaskIdentifier = .invalid
    id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      let expiring = Int64(id.rawValue)
      Task { @MainActor in
        try? await self?.events.onBackgroundTaskExpiring(id: expiring)
        UIApplication.shared.endBackgroundTask(id)
      }
    }
    return id == .invalid ? -1 : Int64(id.rawValue)
  }

  func endBackgroundTask(id: Int64) throws {
    guard id >= 0 else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: Int(id)))
  }
}

/// Short-lived central manager whose only job is to trigger the Bluetooth
/// permission prompt and report when the user has answered.
private final class BluetoothPermissionProbe: NSObject, CBCentralManagerDelegate {
  private var manager: CBCentralManager?
  private var onAnswered: (() -> Void)?

  init(onAnswered: @escaping () -> Void) {
    self.onAnswered = onAnswered
    super.init()
    manager = CBCentralManager(
      delegate: self, queue: .main,
      options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard CBManager.authorization != .notDetermined else { return }
    let done = onAnswered
    onAnswered = nil
    manager = nil
    done?()
  }
}
