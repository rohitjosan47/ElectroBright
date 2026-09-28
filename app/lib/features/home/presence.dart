import '../../app/bluetooth_access.dart';
import '../../core/color/colour_engine.dart';
import '../../core/model/channel_layout.dart';
import '../../core/protocol/eb/eb_scene.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';

/// Where a light is ("Connected", "Unavailable — …", "Firmware update needed",
/// "Updating…"). [bluetooth]: why Bluetooth can't be used, which a light
/// that can't connect for that reason names.
String presenceText(
  AppLocalizations l,
  FixtureStatus s, {
  BluetoothIssue? bluetooth,
}) => presenceOf(
  l,
  s.phase,
  s.incompatibility,
  updating: s.updating,
  bluetooth: bluetooth,
);

/// [presenceText] from the only fields it reads.
String presenceOf(
  AppLocalizations l,
  LinkPhase phase,
  EbIncompatibility? incompatibility, {
  bool updating = false,
  BluetoothIssue? bluetooth,
}) => updating
    ? l.presenceUpdating
    : switch (phase) {
        LinkPhase.ready => l.presenceConnected,
        LinkPhase.connecting ||
        LinkPhase.handshaking ||
        LinkPhase.waiting => l.presenceConnecting,
        LinkPhase.unavailable => l.presenceUnavailable,
        LinkPhase.bluetoothOff => switch (bluetooth) {
          BluetoothIssue.denied => l.presencePermission,
          BluetoothIssue.unsupported => l.presenceBluetoothUnsupported,
          BluetoothIssue.locationOff => l.presenceLocationOff,
          BluetoothIssue.off || null => l.presenceBluetoothOff,
        },
        LinkPhase.incompatible => switch (incompatibility) {
          EbIncompatibility.legacyFirmware => l.presenceUpdateNeeded,
          EbIncompatibility.unknownLayout => l.presenceNewerApp,
          EbIncompatibility.setupNeeded => l.presenceSetupNeeded,
          _ => l.presenceUnexpected,
        },
        LinkPhase.idle => l.presenceIdle,
      };

/// What the light is doing ("On · 64 % · Thunderstorm"); single-white lights
/// report their effective output when the channel is below full.
String stateLine(
  AppLocalizations l,
  EbScene scene, {
  required bool sleeping,
  required String modeName,
}) {
  if (sleeping || scene.brightness == 0) return l.stateOff;
  final String on = scene.layout == ChannelLayout.w && scene.color[0] < 255
      ? l.stateOutputPercent(
          (ColourEngine.output(scene.color[0], scene.brightness) * 100).round(),
        )
      : l.stateOnPercent((scene.brightness / 255 * 100).round());
  return '$on · $modeName';
}
