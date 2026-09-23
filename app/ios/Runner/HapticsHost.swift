import CoreHaptics
import UIKit

/// Renders the app's semantic haptic events (pigeons/platform_api.dart) with
/// UIKit feedback generators, and Core Haptics patterns for the signature
/// moments. Rate limiting and the user's intensity setting live in Dart.
final class HapticsHost: HapticsHostApi {
  private let selection = UISelectionFeedbackGenerator()
  private let light = UIImpactFeedbackGenerator(style: .light)
  private let medium = UIImpactFeedbackGenerator(style: .medium)
  private let rigid = UIImpactFeedbackGenerator(style: .rigid)
  private let soft = UIImpactFeedbackGenerator(style: .soft)
  private let notification = UINotificationFeedbackGenerator()
  private lazy var engine: CHHapticEngine? = makeEngine()

  func prepare(event: HapticEvent) throws {
    switch event {
    case .selection, .detent: selection.prepare()
    case .edge: rigid.prepare()
    case .longPress: medium.prepare()
    case .success, .warning, .error: notification.prepare()
    case .hueDetent, .hueDetentStrong, .powerOn, .powerOff, .presetLoaded, .connected:
      try? engine?.start()
    }
  }

  func play(event: HapticEvent, intensity: Double) throws {
    let i = Float(max(0, min(1, intensity)))
    guard i > 0 else { return }
    switch event {
    case .selection, .detent:
      selection.selectionChanged()
      selection.prepare()  // keep the Taptic Engine warm for the next detent
    case .edge:
      rigid.impactOccurred(intensity: CGFloat(0.7 * i))
    case .longPress:
      medium.impactOccurred(intensity: CGFloat(i))
    case .success:
      notification.notificationOccurred(.success)
    case .warning:
      notification.notificationOccurred(.warning)
    case .error:
      notification.notificationOccurred(.error)
    case .hueDetent:
      if !transients([(0, 0.45 * i, 0.8)]) { light.impactOccurred(intensity: CGFloat(0.5 * i)) }
    case .hueDetentStrong:
      if !transients([(0, 0.75 * i, 0.9)]) { rigid.impactOccurred(intensity: CGFloat(0.7 * i)) }
    case .powerOn:
      if !power(rising: true, intensity: i) { medium.impactOccurred(intensity: CGFloat(0.9 * i)) }
    case .powerOff:
      if !power(rising: false, intensity: i) { soft.impactOccurred(intensity: CGFloat(0.7 * i)) }
    case .presetLoaded:
      if !transients([(0, 0.7 * i, 0.5), (0.09, 0.9 * i, 0.6)]) {
        notification.notificationOccurred(.success)
      }
    case .connected:
      if !transients([(0, 0.4 * i, 0.3), (0.08, 0.6 * i, 0.4)]) {
        light.impactOccurred(intensity: CGFloat(0.6 * i))
      }
    }
  }

  // MARK: Core Haptics

  private func makeEngine() -> CHHapticEngine? {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
    guard let engine = try? CHHapticEngine() else { return nil }
    engine.playsHapticsOnly = true
    engine.isAutoShutdownEnabled = true  // the engine idles itself between gestures
    engine.resetHandler = { [weak engine] in try? engine?.start() }
    return engine
  }

  /// Plays transient taps given as (time s, intensity, sharpness).
  private func transients(_ taps: [(Double, Float, Float)]) -> Bool {
    let events = taps.map { time, intensity, sharpness in
      CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ],
        relativeTime: time)
    }
    return playPattern(events: events, curves: [])
  }

  /// A 150 ms swell (on) or fade (off) with a tap at the bright end.
  private func power(rising: Bool, intensity i: Float) -> Bool {
    let duration = 0.15
    let body = CHHapticEvent(
      eventType: .hapticContinuous,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8 * i),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
      ],
      relativeTime: rising ? 0 : 0.02, duration: duration)
    let curve = CHHapticParameterCurve(
      parameterID: .hapticIntensityControl,
      controlPoints: [
        .init(relativeTime: 0, value: rising ? 0.15 : 1.0),
        .init(relativeTime: duration, value: rising ? 1.0 : 0.0),
      ],
      relativeTime: rising ? 0 : 0.02)
    let tap = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8 * i),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
      ],
      relativeTime: rising ? duration : 0)
    return playPattern(events: [body, tap], curves: [curve])
  }

  private func playPattern(events: [CHHapticEvent], curves: [CHHapticParameterCurve]) -> Bool {
    guard let engine else { return false }
    do {
      try engine.start()
      let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
      let player = try engine.makePlayer(with: pattern)
      try player.start(atTime: CHHapticTimeImmediate)
      return true
    } catch {
      return false
    }
  }
}
