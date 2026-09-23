import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Retained for the lifetime of the engine (Pigeon handlers hold weak-ish refs).
  private var platformHost: PlatformHost?
  private var hapticsHost: HapticsHost?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ElectroBrightNative")
    else { return }
    let messenger = registrar.messenger()
    let platform = PlatformHost(messenger: messenger)
    let haptics = HapticsHost()
    PlatformHostApiSetup.setUp(binaryMessenger: messenger, api: platform)
    HapticsHostApiSetup.setUp(binaryMessenger: messenger, api: haptics)
    platformHost = platform
    hapticsHost = haptics
  }
}
