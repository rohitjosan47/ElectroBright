import 'dart:async';
import 'dart:typed_data';

import '../../core/ble/ble_link.dart';
import '../../core/ble/link_writer.dart';
import '../../core/model/channel_color.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/light_capabilities.dart';
import '../../core/protocol/eb/eb_command.dart';
import '../../core/protocol/eb/eb_constants.dart';
import '../../core/protocol/eb/eb_identity.dart';
import '../../core/protocol/eb/eb_ota.dart';
import '../../core/protocol/eb/eb_reply.dart';
import '../../core/protocol/eb/eb_scene.dart';
import '../../core/protocol/eb/line_reassembler.dart';
import '../../core/util/scheduler.dart';
import 'command_lane.dart';
import 'eb_types.dart';
import 'stream_lane.dart';

const GattRef ebRx = GattRef(Eb.serviceUuid, Eb.rxUuid);
const GattRef ebTx = GattRef(Eb.serviceUuid, Eb.txUuid);

final class EbSessionOptions {
  const EbSessionOptions({
    this.frameGap = const Duration(milliseconds: 25),
    this.handshakeAttempts = const <Duration>[
      Duration(milliseconds: 300),
      Duration(milliseconds: 400),
      Duration(milliseconds: 600),
      Duration(milliseconds: 900),
      Duration(milliseconds: 1300),
    ],
    this.modeSettingsMaxAge = const Duration(seconds: 60),
    this.timerGrace = const Duration(seconds: 3),
  });

  /// Minimum spacing of colour frames (25 ms on iOS, 16 ms on Android).
  final Duration frameGap;

  /// INFO timeouts: the BLE plugin cannot tell when the notification
  /// subscription is live, so the first query is retried with growing waits.
  final List<Duration> handshakeAttempts;

  /// A resume refreshes all 13 slider pairs when older than this.
  final Duration modeSettingsMaxAge;

  /// Ask for STATUS if the timer-expiry push has not arrived this long after
  /// the deadline (it is missed when iOS suspended the app).
  final Duration timerGrace;
}

/// Outcome of a preset action, with the scene the slot holds afterwards.
final class EbPresetResult {
  const EbPresetResult(this.result, [this.scene]);
  final EbResult result;
  final EbScene? scene;
}

/// One connected ElectroBright light (firmware 3.x).
///
/// Ownership model (plan §4.6): while connected, this phone is the light's
/// only writer, so the app owns the scene. The light is authoritative at sync
/// points (handshake, preset load, factory reset) and for sleep and the timer.
/// A value the app set is never overwritten by a stale STATUS; a genuine
/// divergence (a write the light lost) is repaired by re-sending the app's
/// value and counted in diagnostics.
final class EbSession {
  /// [expectedLayout]: what the light is believed to be (saved from an earlier
  /// connection, or guessed from its name). The handshake replaces it with
  /// what the firmware reports before anything is sent.
  EbSession({
    required BleLink link,
    required Scheduler scheduler,
    this.options = const EbSessionOptions(),
    ChannelLayout expectedLayout = ChannelLayout.rgbw,
  }) : _link = link,
       _scheduler = scheduler,
       _layout = expectedLayout {
    _shadow = _defaultState(expectedLayout);
    _desired = _shadow;
    _writer = LinkWriter(link);
    _stream = StreamLane(
      writer: _writer,
      rx: ebRx,
      scheduler: scheduler,
      desired: () =>
          (color: _desired.scene.color, brightness: _desired.scene.brightness),
      onDelivered: _onFrameDelivered,
      minGap: options.frameGap,
    );
    _commands = CommandLane(
      writer: _writer,
      rx: ebRx,
      scheduler: scheduler,
      mtu: () => _link.mtu,
      stream: _stream,
      isRedundant: _isRedundant,
      onDone: _onCommandDone,
      onUnresponsive: () => _events.add(const EbUnresponsive()),
    );
  }

  final BleLink _link;
  final Scheduler _scheduler;
  final EbSessionOptions options;
  late final LinkWriter _writer;
  late final StreamLane _stream;
  late final CommandLane _commands;
  final LineReassembler _lines = LineReassembler();
  StreamSubscription<Uint8List>? _notifications;

  EbPhase _phase = EbPhase.connecting;
  EbFirmware? _firmware;
  ChannelLayout _layout;
  late EbDeviceState _shadow;
  late EbDeviceState _desired;

  /// Set when a STATUS line of the wrong shape arrived during the handshake.
  bool _statusShapeMismatch = false;

  /// See [colorOrigin]: the origin and the colour it was recorded for.
  EbColorOrigin _colorOrigin = const EbColorOrigin.light(0);
  ChannelColor? _originColor;

  /// Key -> sequence number of the newest unconfirmed change to it.
  final Map<String, int> _latest = <String, int>{};
  final Set<String> _gestures = <String>{};
  int _seq = 0;

  int? _gestureStartBrightness;
  int _lastLitBrightness = 255;
  Cancelable? _timerWatch;

  /// Released at 0: the brightness to store in the sleeping light once its
  /// sleep fade is over (so power-on comes back there), and the pending wait.
  int? _wakeBrightness;
  Cancelable? _wakeTimer;

  /// Bumped by each turn-off at zero and by every power-on: a stale wait
  /// never stores anything.
  int _offRun = 0;

  /// How long after SLEEP is answered the light's fade is surely over.
  static const Duration wakeBrightnessDelay = Duration(
    milliseconds: Eb.sleepFadeMs + 150,
  );
  Duration? _modeSettingsAt;
  bool _resyncQueued = false;
  bool _resyncAgain = false;
  bool _resyncAgainFull = false;
  final Map<int, EbScene> _presetScenes = <int, EbScene>{};
  int? _loadingSlot;
  final Map<int, Future<EbResult>> _loadFollowUps = <int, Future<EbResult>>{};

  final StreamController<EbView> _views = StreamController<EbView>.broadcast();
  final StreamController<EbEvent> _events =
      StreamController<EbEvent>.broadcast();
  bool _emitScheduled = false;

  /// Test/diagnostic hook: every send, completion and settle.
  void Function(String line)? debugLog;

  // Diagnostics.
  int malformedLines = 0;
  int strayLines = 0;
  int divergences = 0;
  int resyncs = 0;

  EbPhase get phase => _phase;
  EbFirmware? get firmware => _firmware;

  /// The handshake found the light in setup-needed mode (no fixture type):
  /// its CAPS and VERSION. Kept open by its owner, the session still sends
  /// the commands that mode accepts ([probe], [setType], [diag]).
  ({EbCaps caps, String? version})? get setup => _setup;
  ({EbCaps caps, String? version})? _setup;

  /// CAPS of the light, from the handshake (typed or setup-needed).
  EbCaps? get _caps => _firmware?.caps ?? _setup?.caps;

  /// The light's layout (the expected one until the handshake identified it).
  ChannelLayout get layout => _layout;

  /// What the light can do (assumed from the layout until the handshake).
  LightCapabilities get capabilities =>
      _firmware?.capabilities ?? LightCapabilities.assumed(_layout);
  EbView get view => EbView(
    phase: _phase,
    state: _desired,
    pending: _latest.keys.toSet(),
    firmware: _firmware,
    colorOrigin: colorOrigin,
    gestures: _gestures.toSet(),
  );

  /// Where the colour [view] shows came from (see [EbColorOrigin]).
  EbColorOrigin get colorOrigin {
    // Any change of the shown colour not made by setColor/setLook came from
    // the light; the light confirming the user's value keeps it the user's.
    if (_desired.scene.color != _originColor) {
      _colorOrigin = EbColorOrigin.light(_seq);
      _originColor = _desired.scene.color;
    }
    return _colorOrigin;
  }

  /// The state the light is believed to hold (diagnostics and tests).
  EbDeviceState get confirmed => _shadow;
  Stream<EbView> get views => _views.stream;
  Stream<EbEvent> get events => _events.stream;
  StreamLane get streamLane => _stream;
  CommandLane get commandLane => _commands;
  Duration get now => _scheduler.now;

  /// Nothing queued, in flight, or waiting to be confirmed.
  /// Nothing in flight or scheduled (including the level to wake to that a
  /// release at 0 still has to store).
  bool get isIdle =>
      _commands.isIdle &&
      _stream.isIdle &&
      !_writer.isBusy &&
      !_resyncQueued &&
      _wakeTimer == null;

  static EbDeviceState _defaultState(ChannelLayout layout) => EbDeviceState(
    scene: EbScene.defaults(layout),
    sleeping: false,
    soundOn: true,
    presets: const <int>{},
  );

  // ===========================================================================
  // Lifecycle

  /// Subscribes, identifies the light and loads its complete state. Throws
  /// [EbNoResponse], [EbIncompatible] or [LinkClosedException].
  ///
  /// A light without a fixture type (firmware 3.7.0+ setup-needed mode)
  /// throws [EbIncompatibility.setupNeeded] after CAPS and VERSION, the only
  /// handshake queries that mode accepts. [setupFirst] (the light was in that
  /// mode last time) asks CAPS before INFO, so such a light is never sent a
  /// command outside that set.
  Future<EbFirmware> start({bool setupFirst = false}) async {
    _phase = EbPhase.handshaking;
    _changed();
    _notifications = _link
        .subscribe(ebTx)
        .listen(_onBytes, onError: (Object _) {});
    unawaited(_link.closed.then(_onLinkClosed));

    if (setupFirst) {
      final EbResult caps = await _commands.enqueue(
        const CapsQuery(),
        seq: ++_seq,
        attempts: options.handshakeAttempts,
      );
      _throwIfClosed(caps);
      if (caps.isSuccess && (caps.reply! as EbCaps).setupNeeded) {
        await _setupNeeded(caps.reply! as EbCaps);
      }
      // Given a type since (or older firmware): the usual handshake.
    }
    final EbResult info = await _commands.enqueue(
      const InfoQuery(),
      seq: ++_seq,
      attempts: options.handshakeAttempts,
    );
    _throwIfClosed(info);
    if (info.code == EbError.setupNeeded) {
      final EbResult caps = await _commands.enqueue(
        const CapsQuery(),
        seq: ++_seq,
      );
      _throwIfClosed(caps);
      if (caps.isSuccess && (caps.reply! as EbCaps).setupNeeded) {
        await _setupNeeded(caps.reply! as EbCaps);
      }
    }
    if (!info.isSuccess) throw const EbNoResponse();
    final String model = (info.reply! as EbInfo).model;
    // The model id names the layout, so the pipelined STATUS below is parsed
    // with the right shape (CAPS only confirms it).
    try {
      _layout = EbIdentity.layoutFromModel(model);
    } on EbIdentityError catch (e) {
      throw EbIncompatible(e.kind, e.reason);
    }
    _shadow = _defaultState(_layout);
    _desired = _shadow;
    _changed();

    final List<EbResult> r = await Future.wait(<Future<EbResult>>[
      for (final EbQuery q in const <EbQuery>[
        VersionQuery(),
        CapsQuery(),
        StatusQuery(),
        ModeSettingsQuery(),
        PresetListQuery(),
      ])
        _commands.enqueue(q, seq: ++_seq),
    ]);
    for (final EbResult x in r) {
      _throwIfClosed(x);
      if (!x.isSuccess) {
        if (_statusShapeMismatch) {
          throw EbIncompatible(
            EbIncompatibility.statusShape,
            'STATUS does not match layout ${_layout.wire}',
          );
        }
        throw const EbNoResponse();
      }
    }
    final EbVersion version = r[0].reply! as EbVersion;
    final EbCaps caps = r[1].reply! as EbCaps;
    final EbStatus status = (r[2].reply! as EbStatusReply).status;
    final EbModeSettings levels = r[3].reply! as EbModeSettings;
    final EbPresets presets = r[4].reply! as EbPresets;
    final LightCapabilities capabilities;
    try {
      capabilities = EbIdentity.capabilities(
        fromModel: _layout,
        version: version,
        caps: caps,
        modeSettingsPairs: levels.levels.length,
      );
    } on EbIdentityError catch (e) {
      throw EbIncompatible(e.kind, e.reason);
    }

    // Sync point: the light is authoritative for everything.
    _shadow = EbDeviceState(
      scene: status.applyTo(_withLevels(EbScene.defaults(_layout), levels)),
      sleeping: status.sleeping,
      soundOn: status.soundOn,
      presets: presets.within(capabilities.presetSlots).slots,
      timerDeadline: _deadlineFrom(status),
    );
    _desired = _shadow;
    _latest.clear();
    _modeSettingsAt = _scheduler.now;
    if (_shadow.scene.brightness > 0) {
      _lastLitBrightness = _shadow.scene.brightness;
    }
    _firmware = EbFirmware(
      model: model,
      version: version,
      caps: caps,
      modeCount: levels.levels.length,
      capabilities: capabilities,
      // The update service, and (3.8.2+) a spare slot: CAPS OTA=0 means none.
      wirelessUpdates:
          _link.offers(EbOta.serviceUuid) && caps.updateSlotBytes != 0,
      updateSlotBytes: caps.updateSlotBytes,
    );
    _phase = EbPhase.ready;
    _armTimerWatch();
    _changed();
    return _firmware!;
  }

  /// Ends the handshake of a light in setup-needed mode: VERSION for the
  /// record, then [EbIncompatibility.setupNeeded]. Nothing else is sent.
  Future<Never> _setupNeeded(EbCaps caps) async {
    final EbResult v = await _commands.enqueue(
      const VersionQuery(),
      seq: ++_seq,
    );
    _throwIfClosed(v);
    final String version = v.isSuccess ? (v.reply! as EbVersion).version : '?';
    _setup = (caps: caps, version: v.isSuccess ? version : null);
    throw EbIncompatible(
      EbIncompatibility.setupNeeded,
      'no fixture type yet (firmware $version)',
    );
  }

  /// Stops using the link (the owner disconnects it).
  Future<void> dispose() async {
    _shutdown();
    await _notifications?.cancel();
  }

  void _onLinkClosed(LinkLossReason reason) => _shutdown(reason);

  void _shutdown([LinkLossReason reason = LinkLossReason.requested]) {
    if (_phase == EbPhase.closed) return;
    _phase = EbPhase.closed;
    _timerWatch?.cancel();
    _wakeTimer?.cancel();
    _writer.close(reason);
    _stream.close();
    _commands.close();
    _changed();
  }

  void _throwIfClosed(EbResult r) {
    if (r.outcome == EbOutcome.disconnected) {
      throw const LinkClosedException(LinkLossReason.lost);
    }
  }

  /// Re-reads the light after the app was in the background.
  Future<void> onResume() {
    final Duration? at = _modeSettingsAt;
    final bool stale =
        at == null || _scheduler.now - at > options.modeSettingsMaxAge;
    return resync(full: stale);
  }

  // ===========================================================================
  // Intents (UI)

  /// A finger went down on a control; incoming values never move it now.
  void beginGesture(String key) {
    _gestures.add(key);
    _changed();
    if (key == EbKeys.brightness) {
      _gestureStartBrightness = _desired.scene.brightness;
    }
    // Touching colour or brightness wakes a sleeping light (Home-app
    // behaviour). Frames alone never wake it (firmware rule).
    if ((key == EbKeys.color || key == EbKeys.brightness) &&
        _desired.sleeping) {
      unawaited(setPower(on: true));
    }
  }

  /// The finger lifted: the final value is sent reliably.
  void endGesture(String key) {
    _gestures.remove(key);
    if (key == EbKeys.color) {
      _stream.submit(terminal: true);
    } else if (key == EbKeys.brightness) {
      // The one place a brightness gesture ending at 0 turns the light off.
      if (_desired.scene.brightness == 0) {
        _offAtZero();
      } else {
        _stream.submit(terminal: true);
      }
      _gestureStartBrightness = null;
    }
    _changed();
  }

  /// Completes once the latest colour and brightness reached the light with
  /// response (a fence, released at once). Throws [LinkClosedException] when
  /// the link ended and [FenceFailed] when the light kept refusing the frame.
  Future<void> lookDelivered() async {
    await _stream.fenceAndHold();
    _stream.release();
  }

  /// Sets the base colour; [live] while dragging (unreliable, paced frames).
  /// [color] must have the light's layout. Returns the change's sequence
  /// number (its [EbColorOrigin]), or null when nothing was set.
  int? setColor(ChannelColor color, {bool live = false}) {
    _checkLayout(color);
    if (_phase != EbPhase.ready && _phase != EbPhase.resyncing) return null;
    if (!live && _desired.sleeping) unawaited(setPower(on: true));
    _desired = _desired.copyWith(scene: _desired.scene.copyWith(color: color));
    final int seq = _latest[EbKeys.color] = ++_seq;
    _byUser(color, seq);
    _stream.submit(terminal: !live);
    _changed();
    return seq;
  }

  void _byUser(ChannelColor color, int seq) {
    _colorOrigin = EbColorOrigin.user(seq);
    _originColor = color;
  }

  /// Colour and brightness in one frame (one gesture): used where both must
  /// change together without a visible step, e.g. "use full range" on a
  /// single-white light, identify and the channel test.
  void setLook({ChannelColor? color, int? brightness, bool live = false}) {
    if (color != null) _checkLayout(color);
    if (_phase != EbPhase.ready && _phase != EbPhase.resyncing) return;
    final int br = brightness ?? _desired.scene.brightness;
    if (br > 0) _lastLitBrightness = br;
    if (!live && br > 0 && _desired.sleeping) unawaited(setPower(on: true));
    _desired = _desired.copyWith(
      scene: _desired.scene.copyWith(color: color, brightness: br),
    );
    if (color != null) _byUser(color, _latest[EbKeys.color] = ++_seq);
    if (brightness != null) _latest[EbKeys.brightness] = ++_seq;
    if (!live && br == 0) {
      _offAtZero();
    } else {
      _stream.submit(terminal: !live);
    }
    _changed();
  }

  void _checkLayout(ChannelColor color) {
    if (color.layout != _layout) {
      throw ArgumentError(
        'colour for ${color.layout.wire} on a ${_layout.wire} light',
      );
    }
  }

  /// Result for a mode this light cannot show (nothing is sent).
  static const EbResult unsupportedMode = EbResult(
    EbOutcome.failed,
    code: 'MODE_UNSUPPORTED',
  );

  /// Sets master brightness (0..255). Released at 0 it turns the light off.
  void setBrightness(int brightness, {bool live = false}) {
    if (_phase != EbPhase.ready && _phase != EbPhase.resyncing) return;
    if (brightness > 0) _lastLitBrightness = brightness;
    if (!live && brightness > 0 && _desired.sleeping) {
      unawaited(setPower(on: true));
    }
    _desired = _desired.copyWith(
      scene: _desired.scene.copyWith(brightness: brightness),
    );
    _latest[EbKeys.brightness] = ++_seq;
    // Inside a brightness gesture the release (endGesture) turns it off, so
    // a release sends exactly one SLEEP.
    if (!live && brightness == 0 && !_gestures.contains(EbKeys.brightness)) {
      _offAtZero();
    } else {
      _stream.submit(terminal: !live || brightness == 0);
    }
    _changed();
  }

  /// About to wake the light: a pending wait for the level to wake to is
  /// over. If that level was not sent yet, it is sent now, ahead of the wake
  /// (the caller fences), so the light wakes to it rather than to 0. True
  /// when it sent one.
  bool _wakeBrightnessFirst() {
    _offRun++;
    final int? wake = _wakeBrightness;
    _cancelWakeBrightness();
    if (wake == null || !_desired.sleeping || _desired.scene.brightness != 0) {
      return false;
    }
    _desired = _desired.copyWith(
      scene: _desired.scene.copyWith(brightness: wake),
    );
    _latest[EbKeys.brightness] = ++_seq;
    _stream.submit(terminal: true);
    return true;
  }

  Future<EbResult> setPower({required bool on}) {
    final bool fence = on && _wakeBrightnessFirst();
    if (_desired.sleeping == !on && !_latest.containsKey(EbKeys.power)) {
      return Future<EbResult>.value(EbResult.skipped);
    }
    _desired = _desired.copyWith(
      sleeping: !on,
      timerDeadline: on ? _desired.timerDeadline : null,
    );
    return _send(SetPower(on: on), <String>[
      EbKeys.power,
      if (!on) EbKeys.timer,
    ], fence: fence);
  }

  /// Released at 0 and the link dropped before the level to wake to was
  /// stored: that level (the owner stores it after reconnecting).
  int? get pendingWakeBrightness => _wakeBrightness;

  /// Stores [brightness] in a light that is still asleep at 0 (after a
  /// reconnect); frames never wake it. False when that no longer applies.
  bool storeWakeBrightness(int brightness) {
    if ((_phase != EbPhase.ready && _phase != EbPhase.resyncing) ||
        !_desired.sleeping ||
        _desired.scene.brightness != 0 ||
        _gestures.contains(EbKeys.brightness) ||
        brightness <= 0) {
      return false;
    }
    _desired = _desired.copyWith(
      scene: _desired.scene.copyWith(brightness: brightness),
    );
    _latest[EbKeys.brightness] = ++_seq;
    _stream.submit(terminal: true);
    _changed();
    return true;
  }

  void _cancelWakeBrightness() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _wakeBrightness = null;
  }

  Future<EbResult> setMode(int mode) {
    if (!capabilities.supportsMode(mode)) {
      return Future<EbResult>.value(unsupportedMode);
    }
    if (_desired.scene.mode == mode) {
      return _desired.sleeping ? setPower(on: true) : _skipped;
    }
    final bool wakes = _desired.sleeping;
    final bool fence = wakes && _wakeBrightnessFirst();
    _desired = _desired.copyWith(
      scene: _desired.scene.copyWith(mode: mode),
      sleeping: false,
    );
    return _send(SetMode(mode), <String>[
      EbKeys.mode,
      if (wakes) EbKeys.power,
    ], fence: fence);
  }

  Future<EbResult> setSpeed(int mode, int value) {
    if (!capabilities.supportsMode(mode)) {
      return Future<EbResult>.value(unsupportedMode);
    }
    if (_desired.scene.speeds[mode - 1] == value) return _skipped;
    _desired = _desired.copyWith(scene: _desired.scene.withSpeed(mode, value));
    return _send(SetModeSpeed(mode, value), <String>[EbKeys.speed(mode)]);
  }

  Future<EbResult> setFrequency(int mode, int value) {
    if (!capabilities.supportsMode(mode)) {
      return Future<EbResult>.value(unsupportedMode);
    }
    if (_desired.scene.frequencies[mode - 1] == value) return _skipped;
    _desired = _desired.copyWith(
      scene: _desired.scene.withFrequency(mode, value),
    );
    return _send(SetModeFrequency(mode, value), <String>[
      EbKeys.frequency(mode),
    ]);
  }

  Future<EbResult> setColorMode(EbColorModeKind kind, int value) {
    if (_desired.scene.colorMode(kind) == value) return _skipped;
    _desired = _desired.copyWith(
      scene: _desired.scene.withColorMode(kind, value),
    );
    return _send(SetColorMode(kind, value), <String>[EbKeys.colorMode(kind)]);
  }

  /// One police beacon colour (the light's layout; e.g. a level on W).
  Future<EbResult> setPoliceColor(EbPoliceSlot slot, ChannelColor color) {
    _checkLayout(color);
    if (_desired.scene.police(slot) == color) return _skipped;
    _desired = _desired.copyWith(scene: _desired.scene.withPolice(slot, color));
    return _send(SetPoliceColor(slot, color), <String>[EbKeys.police(slot)]);
  }

  /// Sleep timer in seconds (0 cancels). The countdown runs on the light.
  Future<EbResult> setTimer(int seconds) {
    _desired = _desired.copyWith(
      timerDeadline: seconds == 0
          ? null
          : _scheduler.now + Duration(seconds: seconds),
    );
    return _send(SetTimer(seconds), <String>[EbKeys.timer]);
  }

  Future<EbResult> setSound({required bool on}) {
    if (_desired.soundOn == on) return _skipped;
    _desired = _desired.copyWith(soundOn: on);
    return _send(SetSound(on: on), <String>[EbKeys.sound]);
  }

  /// Saves the light's current scene into [slot]; returns what was saved.
  Future<EbPresetResult> presetSave(int slot) async {
    final EbResult r = await _send(PresetSave(slot), const <String>[]);
    return EbPresetResult(r, r.isSuccess ? _presetScenes[slot] : null);
  }

  /// Loads [slot] (the light wakes); returns the complete loaded scene.
  Future<EbPresetResult> presetLoad(int slot) async {
    final EbResult r = await _send(PresetLoad(slot), const <String>[]);
    if (!r.isSuccess) return EbPresetResult(r);
    // The reply handler queued MODE_SETTINGS at the head of the queue; wait
    // for it so the returned scene has all 13 slider pairs.
    final Future<EbResult>? followUp = _loadFollowUps.remove(slot);
    if (followUp != null) await followUp;
    return EbPresetResult(r, _presetScenes[slot]);
  }

  Future<EbResult> presetDelete(int slot) =>
      _send(PresetDelete(slot), const <String>[]);

  /// Restores factory defaults on the light, then re-reads everything.
  Future<EbResult> factoryReset() async {
    final EbResult r = await _send(const FactoryReset(), const <String>[]);
    if (r.isSuccess || r.outcome == EbOutcome.timedOut) {
      await resync(full: true);
    }
    return r;
  }

  /// IDENTIFY (firmware with CAPS `IDENTIFY=1`): the light flashes twice,
  /// chirps once and restores itself; no state changes.
  Future<EbResult> identify() => _send(const Identify(), const <String>[]);

  /// PROBE (CAPS `PROBE=1`): drives one physical LED output (0 red, 1 green,
  /// 2 blue, 3 white/cool, 4 warm) for up to 3 s, or ends that. Any other
  /// command also ends it; nothing is stored.
  Future<EbResult> probe(int output, {required bool on}) {
    if (!(_caps?.probe ?? false)) return _skipped;
    return _send(Probe(output, on: on), const <String>[]);
  }

  /// SET_TYPE (CAPS `TYPES=`): makes the light a [layout] fixture. On OK the
  /// light has cleared its presets and scene and restarts as the new type, so
  /// the link drops; the next handshake identifies it as that type. The same
  /// type is an OK that changes nothing.
  Future<EbResult> setType(ChannelLayout layout) {
    if (!(_caps?.types.contains(layout.wire) ?? false)) return _skipped;
    return _send(SetType(layout), const <String>[]);
  }

  // ===========================================================================
  // Wireless update (docs/protocol.md §10): the update engine
  // (sessions/firmware_update.dart) uses this link's update service.

  /// Pauses the command and colour lanes: nothing of the normal protocol is
  /// sent until [resumeLanes] (queued changes wait). Idempotent.
  void pauseLanes() {
    if (_lanesPaused) return;
    _lanesPaused = true;
    _commands.paused = true;
    _stream.hold();
  }

  void resumeLanes() {
    if (!_lanesPaused) return;
    _lanesPaused = false;
    _commands.paused = false;
    _stream.release();
  }

  bool _lanesPaused = false;
  bool get lanesPaused => _lanesPaused;

  int get mtu => _link.mtu;

  /// Completes when this session's link ends.
  Future<LinkLossReason> get linkClosed => _link.closed;

  /// Notifications of [ref] (the update control characteristic).
  Stream<Uint8List> subscribeRaw(GattRef ref) => _link.subscribe(ref);

  /// One write in line with the session's own (the link has one writer).
  Future<void> writeRaw(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) => _writer.write(ref, value, withResponse: withResponse);

  /// Round-trip time of a PING, or null.
  Future<Duration?> ping() async {
    final Duration t0 = _scheduler.now;
    final EbResult r = await _commands.enqueue(const Ping(), seq: ++_seq);
    return r.outcome == EbOutcome.ok ? _scheduler.now - t0 : null;
  }

  Future<Map<String, int>?> diag() async {
    final EbResult r = await _commands.enqueue(const DiagQuery(), seq: ++_seq);
    return r.outcome == EbOutcome.ok ? (r.reply! as EbDiag).values : null;
  }

  /// Re-reads the light (fenced, so colour and brightness are comparable) and
  /// repairs any divergence. [full] also refreshes all slider pairs and the
  /// preset list.
  Future<void> resync({bool full = false}) async {
    if (_phase == EbPhase.resyncing) {
      _resyncAgain = true;
      _resyncAgainFull = _resyncAgainFull || full;
      return;
    }
    if (_phase != EbPhase.ready) return;
    _phase = EbPhase.resyncing;
    _changed();
    try {
      bool wantFull = full;
      do {
        resyncs++;
        _resyncAgain = false;
        final int seq = ++_seq;
        final EbResult r = await _commands.enqueue(
          const StatusQuery(),
          seq: seq,
          fence: true,
        );
        if (r.outcome == EbOutcome.ok) {
          _applyResync((r.reply! as EbStatusReply).status, seq);
        }
        if (wantFull && _phase != EbPhase.closed) {
          await _commands.enqueue(const ModeSettingsQuery(), seq: ++_seq);
          await _commands.enqueue(const PresetListQuery(), seq: ++_seq);
        }
        wantFull = _resyncAgainFull;
        _resyncAgainFull = false;
      } while ((_resyncAgain || wantFull) && _phase != EbPhase.closed);
    } finally {
      _resyncQueued = false;
      if (_phase == EbPhase.resyncing) _phase = EbPhase.ready;
      _changed();
    }
  }

  // ===========================================================================
  // Internals

  Future<EbResult> get _skipped => Future<EbResult>.value(EbResult.skipped);

  Future<EbResult> _send(
    EbCommand command,
    List<String> keys, {
    bool fence = false,
  }) {
    final int seq = ++_seq;
    for (final String k in keys) {
      _latest[k] = seq;
    }
    debugLog?.call('send $command #$seq $keys');
    _changed();
    return _commands.enqueue(command, seq: seq, fence: fence);
  }

  /// Released at brightness 0: fence (so the 0 frame lands first), one
  /// SLEEP, and once the light's sleep fade is over, store the pre-drag
  /// brightness in the sleeping light so the next power-on comes back there
  /// (frames never wake it). Sent during the fade, the light would scale it
  /// by the fading gain and visibly flash back up.
  void _offAtZero() {
    final int restore = (_gestureStartBrightness ?? 0) > 0
        ? _gestureStartBrightness!
        : _lastLitBrightness;
    final int run = ++_offRun;
    _cancelWakeBrightness();
    // Pending from now: a link lost before SLEEP is answered keeps it too.
    _wakeBrightness = restore;
    // The 0 frame goes out (reliably) first; the fence below waits for it.
    _stream.submit(terminal: true);
    _desired = _desired.copyWith(sleeping: true, timerDeadline: null);
    unawaited(
      _send(const SetPower(on: false), <String>[
        EbKeys.power,
        EbKeys.timer,
      ], fence: true).then((EbResult r) {
        if (run != _offRun) return;
        if (!r.isSuccess) {
          if (r.outcome != EbOutcome.disconnected) _cancelWakeBrightness();
          return;
        }
        _wakeTimer = _scheduler.after(wakeBrightnessDelay, () {
          _wakeTimer = null;
          if (run != _offRun) return;
          final int? wake = _wakeBrightness;
          _wakeBrightness = null;
          if (wake != null) storeWakeBrightness(wake);
        });
      }),
    );
  }

  bool _isRedundant(EbCommand c) => switch (c) {
    SetMode(:final int mode) => _shadow.scene.mode == mode && !_shadow.sleeping,
    SetModeSpeed(:final int mode, :final int value) =>
      _shadow.scene.speeds[mode - 1] == value,
    SetModeFrequency(:final int mode, :final int value) =>
      _shadow.scene.frequencies[mode - 1] == value,
    SetColorMode(:final EbColorModeKind kind, :final int value) =>
      _shadow.scene.colorMode(kind) == value,
    SetPoliceColor(:final EbPoliceSlot slot, :final ChannelColor color) =>
      _shadow.scene.police(slot) == color,
    SetSound(:final bool on) => _shadow.soundOn == on,
    SetPower(:final bool on) =>
      _shadow.sleeping == !on && (on || _shadow.timerDeadline == null),
    _ => false,
  };

  List<String> _keysOf(EbCommand c) => switch (c) {
    SetMode() => <String>[EbKeys.mode, EbKeys.power],
    SetModeSpeed(:final int mode) => <String>[EbKeys.speed(mode)],
    SetModeFrequency(:final int mode) => <String>[EbKeys.frequency(mode)],
    SetColorMode(:final EbColorModeKind kind) => <String>[
      EbKeys.colorMode(kind),
    ],
    SetPoliceColor(:final EbPoliceSlot slot) => <String>[EbKeys.police(slot)],
    SetPower() => <String>[EbKeys.power, EbKeys.timer],
    SetTimer() => <String>[EbKeys.timer],
    SetSound() => <String>[EbKeys.sound],
    _ => const <String>[],
  };

  /// Runs synchronously in wire order when a command finishes.
  void _onCommandDone(EbCommand c, int seq, EbResult r, List<EbReply> notes) {
    debugLog?.call(
      'done $c #$seq $r '
      '${_keysOf(c).map((String k) => '$k:${_latest[k]}').join(',')}',
    );
    if (notes.any((EbReply n) => n is EbError && n.code == EbError.storage)) {
      _events.add(const EbStorageWarning());
    }
    if (r.outcome == EbOutcome.ok) _applyEffect(c, r, seq);
    if (c is PresetLoad && r.outcome == EbOutcome.failed) {
      if (r.code == EbError.presetEmpty) {
        _shadow = _shadow.copyWith(
          presets: _shadow.presets.difference(<int>{c.slot}),
        );
        _desired = _desired.copyWith(presets: _shadow.presets);
      }
    }
    for (final String key in _keysOf(c)) {
      _settle(key, seq);
    }
    if (!r.isSuccess && r.outcome != EbOutcome.disconnected) {
      _events.add(EbCommandFailed(c, r));
      // A timeout leaves the light's state unknown: re-read it.
      if (r.outcome == EbOutcome.timedOut && _phase == EbPhase.ready) {
        _queueResync(full: c is FactoryReset || c is PresetLoad);
      }
    }
    _armTimerWatch();
    _changed();
  }

  void _applyEffect(EbCommand c, EbResult r, int seq) {
    final EbScene s = _shadow.scene;
    switch (c) {
      case SetMode(:final int mode):
        _shadow = _shadow.copyWith(
          scene: s.copyWith(mode: mode),
          sleeping: false,
        );
      case SetModeSpeed(:final int mode, :final int value):
        _shadow = _shadow.copyWith(scene: s.withSpeed(mode, value));
      case SetModeFrequency(:final int mode, :final int value):
        _shadow = _shadow.copyWith(scene: s.withFrequency(mode, value));
      case SetColorMode(:final EbColorModeKind kind, :final int value):
        _shadow = _shadow.copyWith(scene: s.withColorMode(kind, value));
      case SetPoliceColor(:final EbPoliceSlot slot, :final ChannelColor color):
        _shadow = _shadow.copyWith(scene: s.withPolice(slot, color));
      case SetPower(:final bool on):
        _shadow = _shadow.copyWith(
          sleeping: !on,
          timerDeadline: on ? _shadow.timerDeadline : null,
        );
      case SetTimer(:final int seconds):
        _shadow = _shadow.copyWith(
          timerDeadline: seconds == 0
              ? null
              : _scheduler.now + Duration(seconds: seconds),
        );
      case SetSound(:final bool on):
        _shadow = _shadow.copyWith(soundOn: on);
      case PresetSave(:final int slot):
        _shadow = _shadow.copyWith(presets: <int>{..._shadow.presets, slot});
        _desired = _desired.copyWith(presets: _shadow.presets);
        _presetScenes[slot] = s;
      case PresetDelete(:final int slot):
        _shadow = _shadow.copyWith(
          presets: _shadow.presets.difference(<int>{slot}),
        );
        _desired = _desired.copyWith(presets: _shadow.presets);
        _presetScenes.remove(slot);
      case PresetLoad(:final int slot):
        final EbStatus st = (r.reply! as EbStatusReply).status;
        _shadow = _shadow.copyWith(
          scene: st.applyTo(s),
          sleeping: st.sleeping,
          timerDeadline: _deadlineFrom(st),
          presets: <int>{..._shadow.presets, slot},
        );
        _adoptSyncPoint(seq);
        // The other 12 modes' sliders changed too: read them next.
        _loadingSlot = slot;
        _loadFollowUps[slot] = _commands.enqueue(
          const ModeSettingsQuery(),
          seq: ++_seq,
          atHead: true,
        );
      case FactoryReset():
        _shadow = _defaultState(_layout);
        _adoptSyncPoint(seq);
        _presetScenes.clear();
      case ModeSettingsQuery():
        _shadow = _shadow.copyWith(
          scene: _withLevels(s, r.reply! as EbModeSettings),
        );
        _modeSettingsAt = _scheduler.now;
        for (int m = 1; m <= Eb.numModes; m++) {
          _adoptIfIdle(EbKeys.speed(m));
          _adoptIfIdle(EbKeys.frequency(m));
        }
        final int? loading = _loadingSlot;
        if (loading != null) {
          _presetScenes[loading] = _shadow.scene;
          _loadingSlot = null;
        }
      case PresetListQuery():
        _shadow = _shadow.copyWith(
          presets: (r.reply! as EbPresets)
              .within(capabilities.presetSlots)
              .slots,
        );
        _desired = _desired.copyWith(presets: _shadow.presets);
      default:
        break;
    }
  }

  /// Sync point: adopt every key not changed by the user after [seq].
  void _adoptSyncPoint(int seq) {
    for (final String key in _allKeys) {
      final int? latest = _latest[key];
      if (latest != null && latest > seq) continue;
      _latest.remove(key);
      if (!_gestures.contains(key)) _desired = _copyKey(_desired, _shadow, key);
    }
    _desired = _desired.copyWith(
      soundOn: _shadow.soundOn,
      presets: _shadow.presets,
    );
  }

  void _adoptIfIdle(String key) {
    if (_latest.containsKey(key) || _gestures.contains(key)) return;
    _desired = _copyKey(_desired, _shadow, key);
  }

  /// A command for [key] finished: if it was the newest change, the key is
  /// confirmed (or, on failure, reverts to the light's value).
  void _settle(String key, int seq) {
    if (_latest[key] != seq) return;
    _latest.remove(key);
    if (!_gestures.contains(key)) _desired = _copyKey(_desired, _shadow, key);
  }

  void _onFrameDelivered(StreamValue v) {
    _shadow = _shadow.copyWith(
      scene: _shadow.scene.copyWith(color: v.color, brightness: v.brightness),
    );
    if (!_gestures.contains(EbKeys.color) && _desired.scene.color == v.color) {
      _latest.remove(EbKeys.color);
    }
    if (!_gestures.contains(EbKeys.brightness) &&
        _desired.scene.brightness == v.brightness) {
      _latest.remove(EbKeys.brightness);
    }
    _changed();
  }

  void _onBytes(Uint8List bytes) {
    for (final String line in _lines.add(bytes)) {
      final EbReply reply = parseEbReply(line, layout: _layout);
      if (reply is EbMalformed) {
        malformedLines++;
        if (_phase == EbPhase.handshaking && line.startsWith('STATUS:')) {
          _statusShapeMismatch = true;
        }
        continue;
      }
      if (!_commands.onReply(reply)) _onUnsolicited(reply);
    }
  }

  void _onUnsolicited(EbReply reply) {
    switch (reply) {
      case EbStatusReply(:final EbStatus status):
        _onPushedStatus(status);
      case EbError(code: EbError.storage):
        _events.add(const EbStorageWarning());
      default:
        strayLines++; // late duplicates after a handshake retry, etc.
    }
  }

  /// A STATUS nobody asked for: the timer-expiry push. Only sleep and timer
  /// are adopted; anything else that looks different triggers a fenced resync.
  void _onPushedStatus(EbStatus st) {
    if (_phase != EbPhase.ready && _phase != EbPhase.resyncing) return;
    final bool wasOn = !_shadow.sleeping;
    _shadow = _shadow.copyWith(
      sleeping: st.sleeping,
      timerDeadline: _deadlineFrom(st),
    );
    _adoptIfIdle(EbKeys.power);
    _adoptIfIdle(EbKeys.timer);
    if (st.sleeping && !st.timerActive && wasOn) {
      _events.add(const EbTimerExpired());
    }
    if (_differsFromDesired(st)) _queueResync();
    _armTimerWatch();
    _changed();
  }

  bool _differsFromDesired(EbStatus st) {
    final EbScene d = _desired.scene;
    bool differs(String key, bool same) =>
        !same && !_latest.containsKey(key) && !_gestures.contains(key);
    return differs(EbKeys.color, d.color == st.color) ||
        differs(EbKeys.brightness, d.brightness == st.brightness) ||
        differs(EbKeys.mode, d.mode == st.mode) ||
        differs(EbKeys.speed(st.mode), d.speeds[st.mode - 1] == st.speed) ||
        differs(
          EbKeys.frequency(st.mode),
          d.frequencies[st.mode - 1] == st.frequency,
        ) ||
        differs(EbKeys.sound, _desired.soundOn == st.soundOn);
  }

  void _queueResync({bool full = false}) {
    if (_phase == EbPhase.closed) return;
    if (_phase == EbPhase.resyncing) {
      _resyncAgain = true;
      _resyncAgainFull = _resyncAgainFull || full;
      return;
    }
    final bool first = !_resyncQueued;
    _resyncQueued = true;
    _resyncAgainFull = _resyncAgainFull || full;
    if (!first) return;
    scheduleMicrotask(() {
      final bool wantFull = _resyncAgainFull;
      _resyncAgainFull = false;
      if (_phase == EbPhase.ready) {
        unawaited(resync(full: wantFull));
      } else {
        _resyncQueued = false;
      }
    });
  }

  /// A fenced STATUS answered: it reflects every change queued before [seq].
  void _applyResync(EbStatus st, int seq) {
    final EbDeviceState before = _desired;
    _shadow = _shadow.copyWith(
      scene: st.applyTo(_shadow.scene),
      sleeping: st.sleeping,
      soundOn: st.soundOn,
      timerDeadline: _deadlineFrom(st),
    );
    // The light owns sleep and the timer.
    for (final String key in <String>[EbKeys.power, EbKeys.timer]) {
      if ((_latest[key] ?? 0) > seq || _gestures.contains(key)) continue;
      _latest.remove(key);
      _desired = _copyKey(_desired, _shadow, key);
    }
    // The app owns the scene: a mismatch is a lost write -> resend.
    final List<String> owned = <String>[
      EbKeys.color,
      EbKeys.brightness,
      EbKeys.mode,
      EbKeys.speed(st.mode),
      EbKeys.frequency(st.mode),
      for (final EbColorModeKind k in EbColorModeKind.values)
        EbKeys.colorMode(k),
      for (final EbPoliceSlot p in EbPoliceSlot.values) EbKeys.police(p),
      EbKeys.sound,
    ];
    for (final String key in owned) {
      if ((_latest[key] ?? 0) > seq || _gestures.contains(key)) continue;
      if (_readKey(before, key) == _readKey(_shadow, key)) {
        _latest.remove(key);
        continue;
      }
      if (key == EbKeys.mode && _desired.sleeping) {
        // Re-sending MODE would wake the light; accept the light's mode.
        _desired = _copyKey(_desired, _shadow, key);
        continue;
      }
      divergences++;
      _events.add(EbDivergence(key));
      _resend(key);
    }
  }

  void _resend(String key) {
    final EbScene d = _desired.scene;
    if (key == EbKeys.color || key == EbKeys.brightness) {
      _latest[key] = ++_seq;
      _stream.submit(terminal: true);
      return;
    }
    final EbCommand cmd = switch (key) {
      EbKeys.mode => SetMode(d.mode),
      EbKeys.sound => SetSound(on: _desired.soundOn),
      _ when key.startsWith('speed:') => SetModeSpeed(
        int.parse(key.substring(6)),
        d.speeds[int.parse(key.substring(6)) - 1],
      ),
      _ when key.startsWith('freq:') => SetModeFrequency(
        int.parse(key.substring(5)),
        d.frequencies[int.parse(key.substring(5)) - 1],
      ),
      _ when key.startsWith('colorMode:') => SetColorMode(
        EbColorModeKind.values.byName(key.substring(10)),
        d.colorMode(EbColorModeKind.values.byName(key.substring(10))),
      ),
      _ => SetPoliceColor(
        EbPoliceSlot.values.byName(key.substring(7)),
        d.police(EbPoliceSlot.values.byName(key.substring(7))),
      ),
    };
    unawaited(_send(cmd, <String>[key]));
  }

  void _armTimerWatch() {
    _timerWatch?.cancel();
    _timerWatch = null;
    final Duration? deadline = _shadow.timerDeadline;
    if (deadline == null || _phase == EbPhase.closed) return;
    final Duration wait = deadline + options.timerGrace - _scheduler.now;
    _timerWatch = _scheduler.after(wait.isNegative ? Duration.zero : wait, () {
      _timerWatch = null;
      // The expiry push never arrived (app suspended?): ask the light.
      if (_shadow.timerDeadline != null) _queueResync();
    });
  }

  Duration? _deadlineFrom(EbStatus st) {
    if (!st.timerActive) return null;
    // The light rounds remaining seconds up.
    return _scheduler.now +
        Duration(seconds: st.timerRemainingSec) -
        const Duration(milliseconds: 500);
  }

  void _changed() {
    if (_emitScheduled) return;
    _emitScheduled = true;
    scheduleMicrotask(() {
      _emitScheduled = false;
      if (!_views.isClosed) _views.add(view);
    });
  }

  // ---- per-key access -------------------------------------------------------------

  static final List<String> _allKeys = <String>[
    EbKeys.color,
    EbKeys.brightness,
    EbKeys.mode,
    EbKeys.power,
    EbKeys.timer,
    EbKeys.sound,
    for (int m = 1; m <= Eb.numModes; m++) ...<String>[
      EbKeys.speed(m),
      EbKeys.frequency(m),
    ],
    for (final EbColorModeKind k in EbColorModeKind.values) EbKeys.colorMode(k),
    for (final EbPoliceSlot p in EbPoliceSlot.values) EbKeys.police(p),
  ];

  static Object? _readKey(EbDeviceState s, String key) {
    final EbScene sc = s.scene;
    switch (key) {
      case EbKeys.color:
        return sc.color;
      case EbKeys.brightness:
        return sc.brightness;
      case EbKeys.mode:
        return sc.mode;
      case EbKeys.power:
        return s.sleeping;
      case EbKeys.timer:
        return s.timerDeadline;
      case EbKeys.sound:
        return s.soundOn;
    }
    if (key.startsWith('speed:')) {
      return sc.speeds[int.parse(key.substring(6)) - 1];
    }
    if (key.startsWith('freq:')) {
      return sc.frequencies[int.parse(key.substring(5)) - 1];
    }
    if (key.startsWith('colorMode:')) {
      return sc.colorMode(EbColorModeKind.values.byName(key.substring(10)));
    }
    return sc.police(EbPoliceSlot.values.byName(key.substring(7)));
  }

  /// [to] with [key] taken from [from].
  static EbDeviceState _copyKey(
    EbDeviceState to,
    EbDeviceState from,
    String key,
  ) {
    final EbScene t = to.scene;
    final EbScene f = from.scene;
    switch (key) {
      case EbKeys.color:
        return to.copyWith(scene: t.copyWith(color: f.color));
      case EbKeys.brightness:
        return to.copyWith(scene: t.copyWith(brightness: f.brightness));
      case EbKeys.mode:
        return to.copyWith(scene: t.copyWith(mode: f.mode));
      case EbKeys.power:
        return to.copyWith(sleeping: from.sleeping);
      case EbKeys.timer:
        return to.copyWith(timerDeadline: from.timerDeadline);
      case EbKeys.sound:
        return to.copyWith(soundOn: from.soundOn);
    }
    if (key.startsWith('speed:')) {
      final int m = int.parse(key.substring(6));
      return to.copyWith(scene: t.withSpeed(m, f.speeds[m - 1]));
    }
    if (key.startsWith('freq:')) {
      final int m = int.parse(key.substring(5));
      return to.copyWith(scene: t.withFrequency(m, f.frequencies[m - 1]));
    }
    if (key.startsWith('colorMode:')) {
      final EbColorModeKind k = EbColorModeKind.values.byName(
        key.substring(10),
      );
      return to.copyWith(scene: t.withColorMode(k, f.colorMode(k)));
    }
    final EbPoliceSlot p = EbPoliceSlot.values.byName(key.substring(7));
    return to.copyWith(scene: t.withPolice(p, f.police(p)));
  }

  static EbScene _withLevels(EbScene s, EbModeSettings m) => s.copyWith(
    speeds: <int>[for (final EbLevels l in m.levels) l.speed],
    frequencies: <int>[for (final EbLevels l in m.levels) l.frequency],
  );
}
