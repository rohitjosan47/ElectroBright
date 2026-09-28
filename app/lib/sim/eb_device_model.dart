import 'dart:typed_data';

import '../core/model/channel_color.dart';
import '../core/model/channel_layout.dart';
import '../core/protocol/eb/eb_constants.dart';
import '../core/protocol/eb/eb_fixture_catalog.dart';
import '../core/protocol/eb/eb_scene.dart';
import 'ota_twin.dart';

/// Dart twin of the ElectroBright firmware (v3.8.0, the universal image: the
/// fixture type is stored in the light, every type via [EbFixtureSpec]; with
/// the wireless-update service, see ota_twin.dart): the command parser,
/// controller, persistence policy, reply buffer and the BLE/control-task glue,
/// ported line for line from firmware/core/ElectroBrightCore/src and
/// firmware/test/fwsim/SimDevice.cpp.
///
/// It powers the Demo lights and the simulator integration tests. The
/// differential test (test/fw_in_the_loop/differential_test.dart) feeds the
/// same byte streams to this model and to the real firmware core (fwsim) and
/// requires identical replies and state, so the two cannot drift apart.
///
/// Time is virtual: nothing happens between calls (see [pass], [advance]).
final class EbDeviceModel {
  /// The universal firmware built with [fixture] as a new light's type (the
  /// sketch `firmware/fixtures/<folder>/`); null is a build without a default,
  /// which starts in setup-needed mode until SET_TYPE.
  ///
  /// [version] is the firmware flashed over USB. With [versionFromImage] the
  /// light runs what a wireless update installed: after one, it reports the
  /// version of the image in its running slot (the demo lights). Without it
  /// the version never changes, like fwsim, which is one compiled build (the
  /// OTA differential test).
  EbDeviceModel({
    EbFixtureSpec? fixture = EbFixtureCatalog.rgbw,
    String version = firmwareVersion,
    this.versionFromImage = false,
  }) : buildDefault = fixture,
       flashedVersion = version {
    _rig = _Rig(this);
    boot();
  }

  final EbFixtureSpec? buildDefault;

  /// The active type (fxselect::select at the last boot); [setupSpec] in
  /// setup-needed mode.
  EbFixtureSpec get fixture => _rig.fixture;
  ChannelLayout get layout => fixture.layout;

  /// No type stored and none built in: all LED outputs off, CAPS `LAYOUT=NONE`.
  bool get setupNeeded => identical(fixture, setupSpec);

  /// Setup-needed mode (profiles::kNone). Its layout is a placeholder: no
  /// command that takes a colour is accepted in this mode.
  static const EbFixtureSpec setupSpec = EbFixtureSpec(
    folder: '(no default type)',
    fwsimName: 'none',
    layout: ChannelLayout.rgbw,
    modelId: 'EB-C3-NONE-V1',
    bleName: 'ElectroBright_C3_SETUP',
    capsReply:
        'CAPS:PROTOCOL=1,PWM=15,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,'
        'IDENTIFY=1,TYPES=RGBW,RGB,RGBCCT,CCT,W,PROBE=1,LAYOUT=NONE',
    modeMask: 0,
    colorValues: <int>[0, 0, 0, 0],
    policeAValues: <int>[0, 0, 0, 0],
    policeBValues: <int>[0, 0, 0, 0],
    legacyFrames: false,
  );

  /// Times the light restarted itself (SET_TYPE); the link dropped each time.
  int get restarts => _restarts;
  int _restarts = 0;

  /// Makes flash writes fail (like fwsim `KVFAIL`), for fault tests.
  set flashWritesFail(bool fail) => _flash.failWrites = fail;

  static const String firmwareVersion = '3.8.2';

  /// The firmware flashed over USB (the factory slot's).
  final String flashedVersion;
  final bool versionFromImage;

  /// The version the light runs (VERSION, and what BEGIN compares against).
  String get runningVersion {
    if (!versionFromImage) return flashedVersion;
    final List<int> image = otaFlash.slot[otaFlash.running];
    final int? at = ImageIdentityTwin.find(image);
    final List<int>? v = at == null
        ? null
        : ImageIdentityTwin.universalVersion(image, at);
    return v == null ? flashedVersion : v.join('.');
  }

  /// Test fault: a newly installed firmware never passes its self-check, so
  /// it rolls back at the deadline.
  bool failSelfCheck = false;

  /// The rollback-test mark of the image in the running slot (3.8.1 test
  /// builds, EB_ROLLBACK_TEST): 1 never passes its self-check; 2 freezes its
  /// control task 3 s after boot, and the task watchdog restarts it. Only
  /// with [versionFromImage] (the demo lights run what they installed).
  int _testImage = 0;
  int get _runningTestImage {
    if (!versionFromImage) return 0;
    final List<int> image = otaFlash.slot[otaFlash.running];
    final int? at = ImageIdentityTwin.find(image);
    return at == null ? 0 : ImageIdentityTwin.rollbackTestOf(image, at);
  }

  static const int _freezeAfterMs = 3000;
  static const int _watchdogMs = 3000;

  /// The fake OTA app slots and the bootloader's rollback rules (survive
  /// restarts, like flash).
  final SimOtaFlash otaFlash = SimOtaFlash();
  final List<List<int>> _otaControl = <List<int>>[];
  final List<List<int>> _otaData = <List<int>>[];
  int _otaDataBytes = 0;
  final OtaRepliesTwin _otaReplies = OtaRepliesTwin();
  final List<Uint8List> _otaDelivered = <Uint8List>[];
  bool _otaSubscribed = false;
  bool _fastLink = false;
  bool _selfChecking = false;
  int _bootMs = 0;
  static const int _otaDataBufferBytes = 12288;
  static const int _otaMaxWrite = 516;

  /// This firmware is new and has not confirmed itself yet.
  bool get selfChecking => _selfChecking;

  /// CAPS `OTA=` (selfcheck::updateSlotBytes at boot): the spare slot, when
  /// it holds at least the running one; 0 without.
  int _updateSlotBytes = 0;

  /// The update link parameters are on (ble::setUpdateLink).
  bool get fastLink => _fastLink;
  OtaReceiverTwin get ota => _rig.ota;
  String get modelId => fixture.modelId;
  String get capsReply => '${fixture.capsReply},OTA=$_updateSlotBytes';

  // cfg (Config.h)
  static const int _numModes = 13;
  static const int _numPresets = Eb.numPresets;
  static const int _minLevel = 1;
  static const int _maxLevel = 10;
  static const int _timerMaxSeconds = 86400;
  static const int _sleepFadeMs = 400;
  static const int _timerSleepFadeMs = 2000;
  static const int _persistDebounceMs = 3000;
  static const int _persistMaxLatencyMs = 15000;
  static const int _maxLineLength = 96;
  static const int _maxLinesPerBatch = 24;
  static const int _rxStreamBytes = 1024;
  static const int _egressBytes = 1024;
  static const int _controlWakeMs = 50;
  static const int _identifyOnMs = 150;
  static const int _identifyOffMs = 150;
  static const int _identifyFlashes = 2;
  static const int _probeMs = 3000;

  final _Flash _flash = _Flash();
  late _Rig _rig;
  final _Egress _egress = _Egress(_egressBytes);
  _LineAssembler _assembler = _LineAssembler(_maxLineLength);
  _AssemblerCounters _seen = const _AssemblerCounters(0, 0, 0);
  final List<int> _rxText = <int>[];
  _ColorFrame? _mailbox;
  final List<int> _events = <int>[];
  bool _connected = false;
  bool _subscribed = false;
  int _mtu = 23;
  int _notifyFailures = 0;
  int _now = 1000;
  final List<Uint8List> _delivered = <Uint8List>[];

  // ---- Lifecycle ---------------------------------------------------------------
  void boot() {
    _selfChecking = otaFlash.pendingVerify;
    _updateSlotBytes = SelfCheckTwin.updateSlotBytes(
      otaFlash.spareSize(),
      otaFlash.runningSize(),
    );
    _rig.core.pendingVerify = _selfChecking;
    _rig.core.begin(_now);
    _bootMs = _now;
    _testImage = _runningTestImage;
  }

  /// Power cycle: RAM state is lost, flash survives, the link drops, and the
  /// stored fixture type is read again.
  void reboot() {
    _delivered.clear();
    _otaDelivered.clear();
    _restartNow();
  }

  /// esp_restart(): like [reboot], except that notifications already
  /// delivered to the phone stay delivered.
  void _restartNow() {
    otaFlash.bootloader();
    _rig = _Rig(this);
    _otaControl.clear();
    _otaData.clear();
    _otaDataBytes = 0;
    _otaReplies.clear();
    _otaSubscribed = false;
    _fastLink = false;
    _egress.clear();
    _assembler = _LineAssembler(_maxLineLength);
    _seen = const _AssemblerCounters(0, 0, 0);
    _rxText.clear();
    _mailbox = null;
    _events.clear();
    _connected = false;
    _subscribed = false;
    _mtu = 23;
    _notifyFailures = 0;
    _now += 1500;
    boot();
  }

  // ---- Radio (BleNus.cpp) ----------------------------------------------------------
  void connect() {
    _mtu = 23;
    _connected = true;
    _subscribed = false;
    _otaSubscribed = false;
    _events.add(1);
  }

  void disconnect() {
    _connected = false;
    _subscribed = false;
    _otaSubscribed = false;
    _fastLink = false;
    _events.add(2);
  }

  void setMtu(int mtu) => _mtu = mtu;
  void setOtaSubscribed({required bool subscribed}) =>
      _otaSubscribed = subscribed;

  /// One write to the update control characteristic (OtaControlCallbacks).
  void otaControl(List<int> data) {
    if (_otaControl.length >= 4) return;
    _otaControl.add(data.length > 48 ? const <int>[] : List<int>.of(data));
  }

  /// One write to the update data characteristic (OtaDataCallbacks).
  void otaData(List<int> data) {
    if (data.isEmpty || data.length > _otaMaxWrite) return;
    if (_otaDataBytes + data.length + 4 > _otaDataBufferBytes) return;
    _otaData.add(List<int>.of(data));
    _otaDataBytes += data.length + 4;
  }

  /// Update-control notifications the phone received since the last call.
  List<Uint8List> takeOtaNotifications() {
    final List<Uint8List> out = List<Uint8List>.of(_otaDelivered);
    _otaDelivered.clear();
    return out;
  }

  void setSubscribed({required bool subscribed}) => _subscribed = subscribed;
  void failNextNotifies(int count) => _notifyFailures = count;

  void write(List<int> data) {
    if (data.isEmpty) return;
    if (_isFrameCandidate(data)) {
      // Setup-needed mode has no layout: no frame length matches.
      final _ColorFrame? frame = setupNeeded
          ? null
          : _decodeFrame(data, fixture);
      if (frame != null) {
        _mailbox = frame;
        _rig.stats.binaryOk++;
      } else {
        _rig.stats.binaryBad++;
      }
    } else if (_rxStreamBytes - _rxText.length >= data.length) {
      _rxText.addAll(data);
    } else {
      _rig.stats.rxStreamDrops++;
    }
  }

  bool _notify(List<int> data) {
    if (!_connected) return false;
    if (_notifyFailures > 0) {
      _notifyFailures--;
      return false;
    }
    if (_subscribed) _delivered.add(Uint8List.fromList(data));
    return true;
  }

  int get _maxPayload => _mtu > 3 ? _mtu - 3 : 20;

  // ---- Control task (App.cpp) --------------------------------------------------------
  void passBegin() {
    while (_events.isNotEmpty) {
      final int ev = _events.removeAt(0);
      _egress.clear();
      _assembler.reset();
      if (ev == 1) {
        _rig.core.onConnect();
      } else {
        _rig.core.onDisconnect();
      }
    }
    final _ColorFrame? frame = _mailbox;
    if (frame != null) {
      _mailbox = null;
      _rig.core.onColorFrame(frame, _now);
    }
  }

  void passEnd() {
    final List<String> batch = <String>[];
    void flushBatch() {
      if (batch.isNotEmpty) {
        _rig.core.processLines(batch, _now);
        batch.clear();
      }
    }

    while (_rxText.isNotEmpty) {
      final int got = _rxText.length < 128 ? _rxText.length : 128;
      final List<int> chunk = _rxText.sublist(0, got);
      _rxText.removeRange(0, got);
      _assembler.feed(chunk, (String line) {
        batch.add(line);
        if (batch.length == _maxLinesPerBatch) flushBatch();
      });
    }
    flushBatch();

    // 3b. Wireless update: requests, then data.
    _rig.ota.blocked = _rig.core.restartPending || _selfChecking;
    while (_otaControl.isNotEmpty) {
      _rig.ota.onControl(_otaControl.removeAt(0), _now);
    }
    while (_otaData.isNotEmpty) {
      final List<int> m = _otaData.removeAt(0);
      _otaDataBytes -= m.length + 4;
      _rig.ota.onData(m, _now);
    }
    _rig.ota.tick(_now);

    final _AssemblerCounters c = _assembler.counters;
    _rig.stats.rxLineOverflows += c.overflows - _seen.overflows;
    _rig.stats.rxRejectedBytes += c.rejected - _seen.rejected;
    _seen = c;

    _rig.core.tick(_now);

    if (_connected) {
      final int before = _egress.retries;
      _egress.flush(_maxPayload, _notify);
      _rig.stats.notifyRetries += _egress.retries - before;
      _otaReplies.flush((List<int> d) {
        if (_otaSubscribed) _otaDelivered.add(Uint8List.fromList(d));
        return true;
      });
    } else {
      _egress.clear();
      _otaReplies.clear();
    }

    // SET_TYPE / update: restart once the reply has gone out.
    if (_rig.restartRequested &&
        ((_egress.pending == 0 && _otaReplies.isEmpty) || !_connected)) {
      _rig.core.flushStorage();
      _restarts++;
      _restartNow();
      return;
    }
    _selfCheck();
  }

  /// App.cpp selfCheck(): a new firmware confirms itself, or rolls back.
  void _selfCheck() {
    if (!_selfChecking) return;
    final int since = _now - _bootMs;
    final int test = _testImage;
    if (test == 2 && since >= _freezeAfterMs + _watchdogMs) {
      // Frozen, then reset by the task watchdog: unconfirmed, so the
      // bootloader goes back to the previous firmware.
      _restarts++;
      _restartNow();
      return;
    }
    final int? marker = _flash.updateType;
    final bool typeLoaded = marker == null || marker == _typeValue(fixture);
    // The NVS write-and-read-back goes to the system namespace, which fwsim
    // never fails; the services are always up in the simulation.
    final bool pass =
        test == 0 &&
        !failSelfCheck &&
        typeLoaded &&
        since ~/ 5 >= SelfCheckTwin.minRenderFrames &&
        _updateSlotBytes > 0;
    if (pass) {
      _selfChecking = false;
      _rig.core.pendingVerify = false;
      otaFlash.confirm();
      _flash.updateType = null;
    } else if (since >= SelfCheckTwin.deadlineMs) {
      otaFlash.markInvalid();
      _restarts++;
      _restartNow();
    }
  }

  /// FixtureType value of a spec (None 0, RGBW 1 … W 5, in catalogue order).
  static int _typeValue(EbFixtureSpec spec) {
    final int i = EbFixtureCatalog.all.indexOf(spec);
    return i < 0 ? 0 : i + 1;
  }

  void pass() {
    if (_frozen) return _selfCheck();
    passBegin();
    passEnd();
  }

  /// A freeze test image after its freeze: nothing runs until the watchdog.
  bool get _frozen =>
      _selfChecking && _testImage == 2 && _now - _bootMs >= _freezeAfterMs;

  /// Idle wake-ups: the control task runs at least every 50 ms.
  void advance(int ms) {
    while (ms > 0) {
      final int step = ms < _controlWakeMs ? ms : _controlWakeMs;
      _now += step;
      ms -= step;
      pass();
    }
  }

  List<Uint8List> takeNotifications() {
    final List<Uint8List> out = List<Uint8List>.of(_delivered);
    _delivered.clear();
    return out;
  }

  List<String> takeSounds() {
    final List<String> out = List<String>.of(_rig.sounds);
    _rig.sounds.clear();
    return out;
  }

  // ---- Inspection --------------------------------------------------------------------
  EbScene get scene => _rig.core.scene;
  bool get sleeping => _rig.core.sleeping;
  bool get timerActive => _rig.core.timerActive;
  int get timerRemainingSec => _rig.core.timerRemainingSec(_now);
  bool get soundOn => _rig.core.soundEnabled;
  Set<int> get presetSlots => _rig.store.presetSlots;
  int get now => _now;
  bool get connected => _connected;
  int get mtu => _mtu;
  bool get subscribed => _subscribed;

  /// The demo light's output override (RenderEngine::identifyOverlay): during
  /// an IDENTIFY, true = every LED full, false = dark; null = the light shows
  /// its normal output (scene, or dark when asleep), also once the flashes end.
  bool? get identifyFlash {
    final _Params p = _rig.params;
    if (p.identifyId == 0) return null;
    const int period = _identifyOnMs + _identifyOffMs;
    final int t = _now - p.identifyAt;
    if (t < 0 || t >= period * _identifyFlashes) return null;
    return t % period < _identifyOnMs;
  }

  /// Same shape as fwsim's `STATE` reply.
  Map<String, Object> state() {
    final EbScene s = _rig.core.scene;
    final _Stats st = _rig.stats;
    return <String, Object>{
      'scene': <String, Object>{
        'color': s.color.values,
        'brightness': s.brightness,
        'mode': s.mode,
        'speed': s.speeds,
        'freq': s.frequencies,
        'fireworkColorMode': s.fireworkColorMode,
        'clubColorMode': s.clubColorMode,
        'policeColorMode': s.policeColorMode,
        'policeA': s.policeA.values,
        'policeB': s.policeB.values,
      },
      'sleeping': _rig.core.sleeping ? 1 : 0,
      'timer': <String, Object>{
        'active': _rig.core.timerActive ? 1 : 0,
        'remaining': _rig.core.timerRemainingSec(_now),
      },
      'sound': _rig.core.soundEnabled ? 1 : 0,
      'presets': (_rig.store.presetSlots.toList()..sort()),
      'ota': <String, Object>{
        'active': _rig.ota.active ? 1 : 0,
        'next': _rig.ota.next,
        'size': _rig.ota.size,
        'restarting': _rig.ota.restarting ? 1 : 0,
        'resume': _rig.ota.canResume ? 1 : 0,
        'running': otaFlash.running,
        'boot': otaFlash.boot,
        'pending': otaFlash.pendingVerify ? 1 : 0,
        'rolledBack': otaFlash.rolledBack ? 1 : 0,
        'fast': _fastLink ? 1 : 0,
        'written': otaFlash.slot[otaFlash.spare].length,
      },
      'now': _now,
      'connected': _connected ? 1 : 0,
      'mtu': _mtu,
      'subscribed': _subscribed ? 1 : 0,
      'pendingText': _rxText.length,
      'mailbox': _mailbox == null ? 0 : 1,
      'pendingReplies': _egress.pending,
      'render': <String, Object>{
        'sleeping': _rig.params.sleeping ? 1 : 0,
        'fadeMs': _rig.params.fadeMs,
        'identify': _rig.params.identifyId,
        'ota': _rig.params.ota ? 1 : 0,
        'probe': _rig.params.probe,
      },
      'stats': <String, Object>{
        'rx': st.rxLines,
        'ovf': st.rxLineOverflows,
        'rej': st.rxRejectedBytes,
        'sdrop': st.rxStreamDrops,
        'unk': st.unknownCommands,
        'err': st.commandErrors,
        'coal': st.coalesced,
        'bin': st.binaryOk,
        'binbad': st.binaryBad,
        'gaps': st.binarySeqGaps,
        'nretry': st.notifyRetries,
        'edrop': st.egressDrops,
        'nvsw': st.nvsWrites,
        'nvsf': st.nvsFailures,
      },
    };
  }
}

// ======================================================================================
// Internals (each section names the firmware file it mirrors).

final class _Stats {
  int rxLines = 0;
  int rxLineOverflows = 0;
  int rxRejectedBytes = 0;
  int rxStreamDrops = 0;
  int unknownCommands = 0;
  int commandErrors = 0;
  int coalesced = 0;
  int binaryOk = 0;
  int binaryBad = 0;
  int binarySeqGaps = 0;
  int notifyRetries = 0;
  int egressDrops = 0;
  int nvsWrites = 0;
  int nvsFailures = 0;
}

final class _Params {
  _Params(
    this.scene, {
    required this.sleeping,
    required this.fadeMs,
    this.identifyId = 0,
    this.identifyAt = 0,
    this.probe = 0,
    this.ota = false,
  });
  final EbScene scene;
  final bool sleeping;
  final int fadeMs;

  /// Non-zero: IDENTIFY flashes (a new id restarts them); 0 cancels.
  final int identifyId;

  /// PROBE: 0 = off, else physical output + 1.
  final int probe;

  /// A wireless update is on: effects, identify and probes stop.
  final bool ota;

  /// Virtual time the current [identifyId] was published.
  final int identifyAt;
}

/// Everything a reboot recreates (flash lives in [EbDeviceModel.flash]).
final class _Rig {
  _Rig(this.device) : fixture = _select(device) {
    store = _StateStore(device._flash, stats, fixture.layout);
    core = _Controller(this);
  }

  /// fxselect::select: a stored type wins; without one the build default is
  /// saved and used; a build without one starts in setup-needed mode.
  static EbFixtureSpec _select(EbDeviceModel device) {
    final EbFixtureSpec? stored = device._flash.type;
    if (stored != null) return stored;
    final EbFixtureSpec? fallback = device.buildDefault;
    if (fallback == null) return EbDeviceModel.setupSpec;
    device._flash.type = fallback;
    return fallback;
  }

  final EbDeviceModel device;
  final EbFixtureSpec fixture;
  bool restartRequested = false;
  late final OtaReceiverTwin ota = OtaReceiverTwin(
    flash: device.otaFlash,
    running: ImageIdentityTwin.parseVersion(device.runningVersion)!,
    reply: device._otaReplies.push,
    onActive: (bool active) {
      core.setOtaBusy(active);
      device._fastLink = active && device._connected;
    },
    onRestart: (int finishMs) {
      // The new firmware's self-check expects this type back ("ofx").
      device._flash.updateType = EbDeviceModel._typeValue(fixture);
      device._flash.finishMs = finishMs; // "oend": DIAG endms
      restartRequested = true;
    },
  );
  final _Stats stats = _Stats();
  final List<String> sounds = <String>[];
  late _Params params = _Params(
    EbScene.defaults(fixture.layout),
    sleeping: false,
    fadeMs: 400,
  );
  late final _StateStore store;
  late final _Controller core;

  void sendLine(String line) {
    if (!device._egress.push(line)) stats.egressDrops++;
  }
}

// ---- BinaryFrame.cpp -------------------------------------------------------------------
final class _ColorFrame {
  const _ColorFrame(this.color, this.brightness, this.seq);
  final ChannelColor color;
  final int? brightness;
  final int? seq;
}

// Every frame length in the family (binframe::kMinFrame .. kMaxFrame).
bool _isFrameCandidate(List<int> d) =>
    d.length >= 5 && d.length <= 9 && d[0] == 0xAA;

_ColorFrame? _decodeFrame(List<int> d, EbFixtureSpec fixture) {
  if (!_isFrameCandidate(d)) return null;
  final ChannelLayout l = fixture.layout;
  final int n = l.frameLength;
  if (d.length == n) {
    int sum = l.salt;
    for (int i = 1; i + 1 < n; i++) {
      sum ^= d[i];
    }
    if (sum != d[n - 1]) return null;
    return _ColorFrame(ChannelColor(l, d.sublist(2, 2 + l.n)), d[n - 2], d[1]);
  }
  if (!fixture.legacyFrames || l.n != 4) return null;
  if (d.length == 7) {
    final int sum = d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ 0x55;
    if (sum != d[6]) return null;
    return _ColorFrame(ChannelColor(l, d.sublist(1, 5)), d[5], null);
  }
  if (d.length == 6) {
    final int sum = d[1] ^ d[2] ^ d[3] ^ d[4] ^ 0x55;
    if (sum != d[5]) return null;
    return _ColorFrame(ChannelColor(l, d.sublist(1, 5)), null, null);
  }
  return null;
}

// ---- LineAssembler.h --------------------------------------------------------------------
final class _AssemblerCounters {
  const _AssemblerCounters(this.lines, this.overflows, this.rejected);
  final int lines;
  final int overflows;
  final int rejected;
}

enum _LineState { collecting, overflowed, rejected }

final class _LineAssembler {
  _LineAssembler(this.maxLength);
  final int maxLength;
  final StringBuffer _buf = StringBuffer();
  int _len = 0;
  _LineState _state = _LineState.collecting;
  int _lines = 0;
  int _overflows = 0;
  int _rejected = 0;

  _AssemblerCounters get counters =>
      _AssemblerCounters(_lines, _overflows, _rejected);

  void feed(List<int> data, void Function(String line) onLine) {
    for (final int c in data) {
      if (c == 0x0A || c == 0x0D) {
        _finish(onLine);
        continue;
      }
      if (_state != _LineState.collecting) continue;
      if (c < 0x20 || c >= 0x7F) {
        if (c == 0x09) {
          _append(0x20);
          continue;
        }
        _state = _LineState.rejected;
        continue;
      }
      _append(c);
    }
  }

  void reset() {
    _buf.clear();
    _len = 0;
    _state = _LineState.collecting;
  }

  void _append(int c) {
    if (_len >= maxLength) {
      _state = _LineState.overflowed;
      return;
    }
    _buf.writeCharCode(c);
    _len++;
  }

  void _finish(void Function(String line) onLine) {
    if (_state == _LineState.overflowed) {
      _overflows++;
    } else if (_state == _LineState.rejected) {
      _rejected++;
    } else if (_len > 0) {
      _lines++;
      onLine(_buf.toString());
    }
    reset();
  }
}

// ---- Egress.h ------------------------------------------------------------------------------
final class _Egress {
  _Egress(this.capacity);
  final int capacity;
  final List<int> _buf = <int>[];
  int drops = 0;
  int retries = 0;

  int get pending => _buf.length;

  bool push(String line) {
    final int n = line.length;
    if (n == 0) return true;
    if (n + 1 > capacity) return false;
    bool evicted = false;
    while (_buf.length + n + 1 > capacity) {
      final int nl = _buf.indexOf(0x0A);
      _buf.removeRange(0, nl >= 0 ? nl + 1 : _buf.length);
      evicted = true;
    }
    _buf
      ..addAll(line.codeUnits)
      ..add(0x0A);
    if (evicted) drops++;
    return !evicted;
  }

  void flush(int maxChunk, bool Function(List<int> data) send) {
    final int size = maxChunk == 0 ? 20 : maxChunk;
    while (_buf.isNotEmpty) {
      final int chunk = _buf.length < size ? _buf.length : size;
      if (!send(_buf.sublist(0, chunk))) {
        retries++;
        break;
      }
      _buf.removeRange(0, chunk);
    }
  }

  void clear() => _buf.clear();
}

// ---- MockKv (flash) + StateStore.cpp ----------------------------------------------------
final class _Flash {
  /// The fixture type ("fx", its own namespace: FACTORY_RESET keeps it).
  EbFixtureSpec? type;

  /// The type when the light switched to an update ("ofx", same namespace;
  /// FixtureType value).
  int? updateType;

  /// The last update's END-to-END_OK time ("oend", same namespace).
  int? finishMs;
  EbScene? scene;
  bool? soundEnabled;
  final Map<int, EbScene> presets = <int, EbScene>{};

  /// The preset format marker ("pv"); null on flash of older firmware.
  int? presetFormat;
  bool failWrites = false;
}

/// state/WriteLimiter.h: attempts cfg::kStorageMinIntervalMs apart, at most
/// cfg::kStorageMaxPerMinute commits in any minute (a failed attempt counts
/// for the interval only).
final class _WriteLimiter {
  static const int minIntervalMs = 2000;
  static const int maxPerMinute = 10;
  static const int windowMs = 60000;

  final List<int> _commits = <int>[]; // the last maxPerMinute, oldest first
  int? _last;

  bool allowed(int now) {
    if (_last != null && now - _last! < minIntervalMs) return false;
    return _commits.length < maxPerMinute || now - _commits.first >= windowMs;
  }

  void note(int now, {required bool committed}) {
    _last = now;
    if (!committed) return;
    _commits.add(now);
    if (_commits.length > maxPerMinute) _commits.removeAt(0);
  }
}

final class _StateStore {
  _StateStore(this.kv, this.stats, this.layout);
  final ChannelLayout layout;
  final _Flash kv;
  final _Stats stats;
  EbScene? _shadow;
  bool _dirty = false;
  int _firstDirty = 0;
  int _lastDirty = 0;
  final Set<int> presetSlots = <int>{};

  // Held writes (StateStore: over the write budget).
  final _WriteLimiter _limiter = _WriteLimiter();
  bool _failing = false;
  bool? _heldSound;
  final Map<int, EbScene> _heldSaves = <int, EbScene>{};
  final Set<int> _heldDeletes = <int>{};

  bool get hasHeldWrites =>
      _heldSound != null || _heldSaves.isNotEmpty || _heldDeletes.isNotEmpty;

  bool _noteWrite(bool ok) {
    if (ok) {
      stats.nvsWrites++;
    } else {
      stats.nvsFailures++;
    }
    _failing = !ok;
    return ok;
  }

  bool _mayWriteNow(int now) => _failing || _limiter.allowed(now);

  (EbScene, bool) load() {
    final EbScene scene;
    if (kv.scene != null) {
      scene = kv.scene!;
      _shadow = kv.scene;
    } else {
      scene = EbScene.defaults(layout);
      _shadow = null;
    }
    final bool sound = kv.soundEnabled ?? true;
    _ensurePresetFormat();
    presetSlots
      ..clear()
      ..addAll(kv.presets.keys);
    _dirty = false;
    return (scene, sound);
  }

  // StateStore::kPresetFormat / kLegacyPresetSlots
  static const int _presetFormat = 2;
  static const int _legacyPresetSlots = 25;

  /// StateStore::ensurePresetFormat: without the current marker, every slot
  /// older firmware could have used is erased (scene and settings kept), then
  /// the marker is written; a failed erase leaves it for the next boot.
  void _ensurePresetFormat() {
    if (kv.presetFormat == _presetFormat) return;
    if (kv.failWrites) {
      stats.nvsFailures += _legacyPresetSlots;
      return;
    }
    kv.presets.clear();
    if (_noteWrite(!kv.failWrites)) kv.presetFormat = _presetFormat;
  }

  void noteSceneChanged(int now) {
    if (!_dirty) _firstDirty = now;
    _dirty = true;
    _lastDirty = now;
  }

  bool tick(int now, EbScene scene) {
    if (!_limiter.allowed(now)) return true;
    if (hasHeldWrites) {
      final bool ok = _commitNextHeld();
      _limiter.note(now, committed: ok);
      return ok;
    }
    if (!_dirty) return true;
    final bool quiet = now - _lastDirty >= EbDeviceModel._persistDebounceMs;
    final bool overdue =
        now - _firstDirty >= EbDeviceModel._persistMaxLatencyMs;
    if (!quiet && !overdue) return true;
    if (_shadow != null && _shadow == scene) {
      _dirty = false; // nothing to write: no commit spent
      return true;
    }
    final bool ok = _flush(scene);
    _limiter.note(now, committed: ok);
    return ok;
  }

  bool _flush(EbScene scene) {
    _dirty = false;
    if (_shadow != null && _shadow == scene) return true;
    if (!_noteWrite(!kv.failWrites)) {
      _dirty = true;
      return false;
    }
    kv.scene = scene;
    _shadow = scene;
    return true;
  }

  /// StateStore::flushAll: everything held and a changed scene, now.
  bool flushAll(EbScene scene) {
    bool ok = true;
    if (_heldSound != null) ok = _commitSettings() && ok;
    for (int i = 0; i < EbDeviceModel._numPresets; i++) {
      if (_heldSaves.containsKey(i) || _heldDeletes.contains(i)) {
        ok = _commitHeldPreset(i) && ok;
      }
    }
    if (_dirty) ok = _flush(scene) && ok;
    return ok;
  }

  bool _commitSettings() {
    final bool ok = _noteWrite(!kv.failWrites);
    if (ok) {
      kv.soundEnabled = _heldSound;
      _heldSound = null;
    }
    return ok;
  }

  bool _commitHeldPreset(int id) {
    final bool ok = _noteWrite(!kv.failWrites);
    if (!ok) return false;
    if (_heldDeletes.remove(id)) {
      kv.presets.remove(id);
    } else {
      kv.presets[id] = _heldSaves.remove(id)!;
    }
    return true;
  }

  bool _commitNextHeld() {
    if (_heldSound != null) return _commitSettings();
    final Iterable<int> pending = _heldDeletes.isNotEmpty
        ? _heldDeletes
        : _heldSaves.keys;
    final int id = pending.reduce((int a, int b) => a < b ? a : b);
    return _commitHeldPreset(id);
  }

  bool saveSettings({required bool soundEnabled, required int now}) {
    _heldSound = soundEnabled;
    if (!_mayWriteNow(now)) return true;
    final bool ok = _commitSettings();
    _limiter.note(now, committed: ok);
    return ok;
  }

  bool savePreset(int id, EbScene scene, int now) {
    if (id >= EbDeviceModel._numPresets) return false;
    _heldDeletes.remove(id);
    if (!_mayWriteNow(now)) {
      _heldSaves[id] = scene;
      presetSlots.add(id);
      return true;
    }
    _heldSaves.remove(id);
    final bool ok = _noteWrite(!kv.failWrites);
    _limiter.note(now, committed: ok);
    if (ok) {
      kv.presets[id] = scene;
      presetSlots.add(id);
    }
    return ok;
  }

  EbScene? loadPreset(int id) {
    if (id >= EbDeviceModel._numPresets) return null;
    final EbScene? held = _heldSaves[id];
    if (held != null) return held;
    if (_heldDeletes.contains(id)) return null;
    final EbScene? s = kv.presets[id];
    if (s != null) {
      presetSlots.add(id);
    } else {
      presetSlots.remove(id);
    }
    return s;
  }

  bool deletePreset(int id, int now) {
    if (id >= EbDeviceModel._numPresets) return false;
    _heldSaves.remove(id);
    if (!_mayWriteNow(now)) {
      _heldDeletes.add(id);
      presetSlots.remove(id);
      return true;
    }
    _heldDeletes.remove(id);
    final bool ok = _noteWrite(!kv.failWrites);
    _limiter.note(now, committed: ok);
    if (ok) {
      kv.presets.remove(id);
      presetSlots.remove(id);
    }
    return ok;
  }

  /// StateStore::clearForTypeChange: scene and every preset slot go (they
  /// belong to the old layout), held presets too; settings stay.
  bool clearForTypeChange() {
    final bool ok = _noteWrite(!kv.failWrites);
    if (ok) {
      kv
        ..scene = null
        ..presets.clear();
    }
    presetSlots.clear();
    _shadow = null;
    _dirty = false;
    _heldSaves.clear();
    _heldDeletes.clear();
    return ok;
  }

  bool factoryReset() {
    final bool ok = _noteWrite(!kv.failWrites);
    if (ok) {
      kv
        ..scene = null
        ..soundEnabled = null
        ..presetFormat = null
        ..presets.clear();
    }
    presetSlots.clear();
    _shadow = null;
    _dirty = false;
    _heldSound = null;
    _heldSaves.clear();
    _heldDeletes.clear();
    return ok;
  }
}

// ---- CommandParser.cpp --------------------------------------------------------------------
enum _Cmd {
  rgbw,
  brightness,
  mode,
  speed,
  frequency,
  fireworkColorMode,
  clubColorMode,
  policeColorMode,
  policeColorA,
  policeColorB,
  presetSave,
  presetLoad,
  presetDelete,
  presetList,
  status,
  modeSettings,
  modeSpeed,
  modeFrequency,
  modeCapabilities,
  sleep,
  wake,
  soundOn,
  soundOff,
  timer,
  factoryReset,
  info,
  version,
  caps,
  ping,
  diag,
  identify,
  setType,
  probe,
}

final class _Spec {
  const _Spec(
    this.name,
    this.id,
    this.argc,
    this.firstMin,
    this.firstMax,
    this.restMin,
    this.restMax,
    this.error,
  );
  final String name;
  final _Cmd id;
  final int argc;
  final int firstMin;
  final int firstMax;
  final int restMin;
  final int restMax;
  final String error;
}

const int _lo = EbDeviceModel._minLevel;
const int _hi = EbDeviceModel._maxLevel;
const int _modes = EbDeviceModel._numModes;
const int _presetMax = EbDeviceModel._numPresets - 1;

const List<_Spec> _specs = <_Spec>[
  _Spec('RGBW', _Cmd.rgbw, 4, 0, 255, 0, 255, 'FORMAT'),
  _Spec('COLOR', _Cmd.rgbw, 4, 0, 255, 0, 255, 'FORMAT'),
  _Spec('BRIGHTNESS', _Cmd.brightness, 1, 0, 255, 0, 0, 'BRIGHTNESS_INVALID'),
  _Spec('MODE', _Cmd.mode, 1, 1, _modes, 0, 0, 'MODE_INVALID'),
  _Spec('SPEED', _Cmd.speed, 1, _lo, _hi, 0, 0, 'SPEED_OUT_OF_BOUNDS'),
  _Spec('FREQUENCY', _Cmd.frequency, 1, _lo, _hi, 0, 0, 'FREQUENCY_INVALID'),
  _Spec(
    'FIREWORK_COLOR_MODE',
    _Cmd.fireworkColorMode,
    1,
    0,
    1,
    0,
    0,
    'FIREWORK_COLOR_MODE_INVALID',
  ),
  _Spec(
    'CLUB_COLOR_MODE',
    _Cmd.clubColorMode,
    1,
    0,
    1,
    0,
    0,
    'CLUB_COLOR_MODE_INVALID',
  ),
  _Spec(
    'POLICE_COLOR_MODE',
    _Cmd.policeColorMode,
    1,
    0,
    1,
    0,
    0,
    'POLICE_COLOR_MODE_INVALID',
  ),
  _Spec('POLICE_COLOR_A', _Cmd.policeColorA, 4, 0, 255, 0, 255, 'FORMAT'),
  _Spec('POLICE_COLOR_B', _Cmd.policeColorB, 4, 0, 255, 0, 255, 'FORMAT'),
  _Spec('PRESET_SAVE', _Cmd.presetSave, 1, 0, _presetMax, 0, 0, 'PRESET_ID'),
  _Spec('PRESET_LOAD', _Cmd.presetLoad, 1, 0, _presetMax, 0, 0, 'PRESET_ID'),
  _Spec(
    'PRESET_DELETE',
    _Cmd.presetDelete,
    1,
    0,
    _presetMax,
    0,
    0,
    'PRESET_ID',
  ),
  _Spec('PRESET_LIST', _Cmd.presetList, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('STATUS', _Cmd.status, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('MODE_SETTINGS', _Cmd.modeSettings, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec(
    'MODE_SPEED',
    _Cmd.modeSpeed,
    2,
    1,
    _modes,
    _lo,
    _hi,
    'MODE_SPEED_INVALID',
  ),
  _Spec(
    'MODE_FREQUENCY',
    _Cmd.modeFrequency,
    2,
    1,
    _modes,
    _lo,
    _hi,
    'MODE_FREQUENCY_INVALID',
  ),
  _Spec(
    'MODE_CAPABILITIES',
    _Cmd.modeCapabilities,
    1,
    1,
    _modes,
    0,
    0,
    'MODE_INVALID',
  ),
  _Spec('SLEEP', _Cmd.sleep, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('WAKE', _Cmd.wake, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('SOUND_ON', _Cmd.soundOn, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('SOUND_OFF', _Cmd.soundOff, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec(
    'TIMER',
    _Cmd.timer,
    1,
    0,
    EbDeviceModel._timerMaxSeconds,
    0,
    0,
    'FORMAT',
  ),
  _Spec('FACTORY_RESET', _Cmd.factoryReset, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('INFO', _Cmd.info, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('VERSION', _Cmd.version, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('CAPS', _Cmd.caps, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('PING', _Cmd.ping, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('DIAG', _Cmd.diag, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('IDENTIFY', _Cmd.identify, 0, 0, 0, 0, 0, 'FORMAT'),
  _Spec('SET_TYPE', _Cmd.setType, 1, 0, 0, 0, 0, 'TYPE_INVALID'),
  _Spec('PROBE', _Cmd.probe, 2, 0, 4, 0, 1, 'PROBE_INVALID'),
];

enum _ParseStatus { ok, unknown, format, range }

final class _Parsed {
  const _Parsed.ok(this.id, this.args) : status = _ParseStatus.ok, error = null;
  const _Parsed.fail(this.status, this.error, [this.id]) : args = const <int>[];
  final _ParseStatus status;
  final _Cmd? id;
  final List<int> args;
  final String? error;
}

bool _isSpace(int c) => c == 0x20 || c == 0x09;

/// parseField(): 0 = ok, 1 = format error, 2 = too large.
(int, int) _parseField(String s, int begin, int end) {
  while (begin < end && _isSpace(s.codeUnitAt(begin))) {
    begin++;
  }
  while (end > begin && _isSpace(s.codeUnitAt(end - 1))) {
    end--;
  }
  if (begin == end) return (1, 0);
  int v = 0;
  for (int p = begin; p < end; p++) {
    final int c = s.codeUnitAt(p);
    if (c < 0x30 || c > 0x39) return (1, 0);
    v = v * 10 + (c - 0x30);
    if (v > 1000000000) return (2, 0);
  }
  return (0, v);
}

/// Colour commands take one value per layout channel (CommandParser.cpp).
bool _isColorCommand(_Cmd id) =>
    id == _Cmd.rgbw || id == _Cmd.policeColorA || id == _Cmd.policeColorB;

bool _takesMode(_Cmd id) =>
    id == _Cmd.mode ||
    id == _Cmd.modeSpeed ||
    id == _Cmd.modeFrequency ||
    id == _Cmd.modeCapabilities;

_Parsed _parseCommand(String line, EbFixtureSpec fixture) {
  final ChannelLayout layout = fixture.layout;
  int begin = 0;
  while (begin < line.length && _isSpace(line.codeUnitAt(begin))) {
    begin++;
  }
  int end = line.length;
  while (end > begin && _isSpace(line.codeUnitAt(end - 1))) {
    end--;
  }
  final int colonIdx = line.indexOf(':', begin);
  final int? colon = colonIdx >= 0 && colonIdx < end ? colonIdx : null;
  int nameEnd = colon ?? end;
  while (nameEnd > begin && _isSpace(line.codeUnitAt(nameEnd - 1))) {
    nameEnd--;
  }
  final String name = line.substring(begin, nameEnd).toUpperCase();
  _Spec? spec;
  for (final _Spec s in _specs) {
    if (s.name == name) {
      spec = s;
      break;
    }
  }
  if (spec == null) {
    return const _Parsed.fail(_ParseStatus.unknown, 'UNKNOWN_CMD');
  }
  // RGBW is the RGBW light's own alias of COLOR (setup-needed mode has no
  // layout at all).
  if (spec.name == 'RGBW' &&
      (!layout.acceptsRgbwAlias ||
          identical(fixture, EbDeviceModel.setupSpec))) {
    return const _Parsed.fail(_ParseStatus.unknown, 'UNKNOWN_CMD');
  }
  final int argc = _isColorCommand(spec.id) ? layout.n : spec.argc;

  final int args = colon != null ? colon + 1 : end;
  int p = args;
  while (p < end && _isSpace(line.codeUnitAt(p))) {
    p++;
  }
  final bool noArgText = p == end;

  if (argc == 0) {
    return noArgText
        ? _Parsed.ok(spec.id, const <int>[])
        : _Parsed.fail(_ParseStatus.format, spec.error, spec.id);
  }
  if (colon == null || noArgText) {
    return _Parsed.fail(_ParseStatus.format, spec.error, spec.id);
  }
  if (spec.id == _Cmd.setType) {
    // A type name (case-insensitive), not a number: the catalogue index.
    final int type = EbFixtureCatalog.all.indexWhere(
      (EbFixtureSpec f) =>
          f.layout.wire == line.substring(p, end).toUpperCase(),
    );
    return type < 0
        ? _Parsed.fail(_ParseStatus.range, spec.error, spec.id)
        : _Parsed.ok(spec.id, <int>[type]);
  }
  // PROBE separates its numbers with a colon (PROBE:3:1).
  final int separator = spec.id == _Cmd.probe ? 0x3A : 0x2C;

  final List<int> values = <int>[];
  int fieldStart = args;
  for (int q = args; ; q++) {
    if (q == end || line.codeUnitAt(q) == separator) {
      if (values.length == argc) {
        int t = fieldStart;
        while (t < q && _isSpace(line.codeUnitAt(t))) {
          t++;
        }
        if (t != q || q != end) {
          return _Parsed.fail(_ParseStatus.format, spec.error, spec.id);
        }
        break;
      }
      final (int rc, int v) = _parseField(line, fieldStart, q);
      if (rc == 1) {
        return _Parsed.fail(_ParseStatus.format, spec.error, spec.id);
      }
      final bool first = values.isEmpty;
      final int lo = first ? spec.firstMin : spec.restMin;
      final int hi = first ? spec.firstMax : spec.restMax;
      if (rc == 2 || v < lo || v > hi) {
        return _Parsed.fail(_ParseStatus.range, spec.error, spec.id);
      }
      values.add(v);
      if (q == end) break;
      fieldStart = q + 1;
    }
  }
  if (values.length != argc) {
    return _Parsed.fail(_ParseStatus.format, spec.error, spec.id);
  }
  // A mode this fixture cannot show is out of range, like MODE:14.
  if (_takesMode(spec.id) && (fixture.modeMask >> (values[0] - 1)) & 1 == 0) {
    return _Parsed.fail(_ParseStatus.range, spec.error, spec.id);
  }
  return _Parsed.ok(spec.id, values);
}

bool _isCoalescible(_Cmd id) =>
    id == _Cmd.rgbw ||
    id == _Cmd.brightness ||
    id == _Cmd.speed ||
    id == _Cmd.frequency;

bool _isQuery(_Cmd id) => switch (id) {
  _Cmd.presetList ||
  _Cmd.status ||
  _Cmd.modeSettings ||
  _Cmd.modeCapabilities ||
  _Cmd.info ||
  _Cmd.version ||
  _Cmd.caps ||
  _Cmd.ping ||
  _Cmd.diag => true,
  _ => false,
};

// ---- ControllerCore.cpp + Replies.cpp -----------------------------------------------------
final class _Controller {
  _Controller(this._rig);
  final _Rig _rig;

  late EbScene scene = EbScene.defaults(_rig.fixture.layout);
  late final bool _setup = identical(_rig.fixture, EbDeviceModel.setupSpec);
  bool _restartPending = false;
  bool _otaBusy = false;

  /// ControllerCore::setPendingVerify: SET_TYPE and FACTORY_RESET are busy.
  bool pendingVerify = false;
  bool get restartPending => _restartPending;
  bool get otaBusy => _otaBusy;

  /// ControllerCore::flushStorage: held writes before a planned restart.
  void flushStorage() {
    if (!_setup) _rig.store.flushAll(scene);
  }

  /// ControllerCore::setOtaBusy.
  void setOtaBusy(bool busy) {
    if (busy == _otaBusy) return;
    _otaBusy = busy;
    if (busy) {
      _identifying = false;
      _probe = 0;
    }
    _publish();
  }

  int _probe = 0;
  int _probeDeadline = 0;
  bool soundEnabled = true;
  bool sleeping = false;
  int _fadeMs = EbDeviceModel._sleepFadeMs;
  bool timerActive = false;
  int _timerDeadline = 0;
  bool _haveSeq = false;
  int _expectedSeq = 0;
  bool _storageErrorReported = false;
  bool _identifying = false;
  int _identifySeq = 0;
  int _identifyAt = 0;

  void begin(int now) {
    // Setup-needed mode loads nothing; nothing is stored until SET_TYPE.
    if (!_setup) {
      final (EbScene s, bool sound) = _rig.store.load();
      scene = s;
      soundEnabled = sound;
    }
    sleeping = false;
    timerActive = false;
    _fadeMs = EbDeviceModel._sleepFadeMs;
    _publish();
    _sound('Boot');
  }

  void onConnect() => _haveSeq = false;

  void onDisconnect() => _haveSeq = false;

  void tick(int now) {
    if (_probe != 0 && now - _probeDeadline >= 0) {
      _probe = 0;
      _publish();
    }
    if (_restartPending) return;
    if (timerActive && now - _timerDeadline >= 0) {
      timerActive = false;
      _identifying = false;
      _sleep(EbDeviceModel._timerSleepFadeMs);
      _sound('Sleep');
      _sendStatus(now);
    }
    _checkStorage(_rig.store.tick(now, scene));
  }

  int timerRemainingSec(int now) {
    if (!timerActive) return 0;
    final int left = _timerDeadline - now;
    if (left <= 0) return 0;
    return (left + 999) ~/ 1000;
  }

  void onColorFrame(_ColorFrame f, int now) {
    if (_setup || _restartPending || _otaBusy) return;
    _probe = 0;
    final int? seq = f.seq;
    if (seq != null) {
      if (_haveSeq && seq != _expectedSeq) _rig.stats.binarySeqGaps++;
      _haveSeq = true;
      _expectedSeq = (seq + 1) & 0xFF;
    }
    _identifying = false;
    scene = scene.copyWith(
      color: f.color,
      brightness: f.brightness ?? scene.brightness,
    );
    _sceneChanged(now);
    _publish();
  }

  void processLines(List<String> lines, int now) {
    int i = 0;
    while (i < lines.length) {
      final int n = lines.length - i < EbDeviceModel._maxLinesPerBatch
          ? lines.length - i
          : EbDeviceModel._maxLinesPerBatch;
      final List<_Parsed> results = <_Parsed>[
        for (int k = 0; k < n; k++) _parseCommand(lines[i + k], _rig.fixture),
      ];
      for (int k = 0; k < n; k++) {
        if (_restartPending) return;
        _rig.stats.rxLines++;
        final _Parsed r = results[k];
        if (r.status == _ParseStatus.unknown) {
          _rig.stats.unknownCommands++;
          _reportError(r.error!);
          continue;
        }
        if (_setup && !_allowedInSetup(r.id!)) {
          _rig.stats.commandErrors++;
          _reportError('SETUP_NEEDED');
          continue;
        }
        if ((_otaBusy && !_isQuery(r.id!)) ||
            (pendingVerify &&
                (r.id == _Cmd.setType || r.id == _Cmd.factoryReset))) {
          _rig.stats.commandErrors++;
          _reportError('BUSY');
          continue;
        }
        if (r.status != _ParseStatus.ok) {
          _rig.stats.commandErrors++;
          _reportError(r.error!);
          continue;
        }
        if (_isCoalescible(r.id!) &&
            k + 1 < n &&
            results[k + 1].status == _ParseStatus.ok &&
            results[k + 1].id == r.id) {
          _rig.stats.coalesced++;
          continue;
        }
        _execute(r.id!, r.args, now);
      }
      i += n;
    }
  }

  void _execute(_Cmd id, List<int> a, int now) {
    // Any state change cancels a running IDENTIFY, then applies normally.
    if (_identifying && id != _Cmd.identify && !_isQuery(id)) {
      _identifying = false;
      _publish();
    }
    // Any other command ends a PROBE.
    if (_probe != 0 && id != _Cmd.probe) {
      _probe = 0;
      _publish();
    }
    switch (id) {
      case _Cmd.rgbw:
        scene = scene.copyWith(color: ChannelColor(_rig.fixture.layout, a));
        _sceneChanged(now);
        _publish();
      case _Cmd.brightness:
        scene = scene.copyWith(brightness: a[0]);
        _sceneChanged(now);
        _publish();
      case _Cmd.mode:
        scene = scene.copyWith(mode: a[0]);
        _wake();
        _sceneChanged(now);
        _publish();
        _sound('ModeChange');
        _rig.sendLine('OK');
      case _Cmd.speed:
        scene = scene.withSpeed(scene.mode, a[0]);
        _sceneChanged(now);
        _publish();
      case _Cmd.frequency:
        scene = scene.withFrequency(scene.mode, a[0]);
        _sceneChanged(now);
        _publish();
      case _Cmd.modeSpeed:
        scene = scene.withSpeed(a[0], a[1]);
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.modeFrequency:
        scene = scene.withFrequency(a[0], a[1]);
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.fireworkColorMode:
        scene = scene.copyWith(fireworkColorMode: a[0]);
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.clubColorMode:
        scene = scene.copyWith(clubColorMode: a[0]);
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.policeColorMode:
        scene = scene.copyWith(policeColorMode: a[0]);
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.policeColorA:
        scene = scene.copyWith(policeA: ChannelColor(_rig.fixture.layout, a));
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.policeColorB:
        scene = scene.copyWith(policeB: ChannelColor(_rig.fixture.layout, a));
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.presetSave:
        if (_rig.store.savePreset(a[0], scene, now)) {
          _sound('Save');
          _rig.sendLine('OK');
        } else {
          _reportError('STORAGE');
        }
      case _Cmd.presetLoad:
        final EbScene? loaded = _rig.store.loadPreset(a[0]);
        if (loaded != null) {
          scene = loaded;
          _wake();
          _sceneChanged(now);
          _publish();
          _sound('Load');
          _sendStatus(now);
        } else {
          _rig.sendLine('ERROR:PRESET_EMPTY:${a[0]}');
          _sound('Error');
        }
      case _Cmd.presetDelete:
        if (_rig.store.deletePreset(a[0], now)) {
          _sound('Delete');
          _rig.sendLine('OK');
        } else {
          _reportError('STORAGE');
        }
      case _Cmd.presetList:
        final List<int> slots = _rig.store.presetSlots.toList()..sort();
        _rig.sendLine('PRESETS:${slots.map((int s) => '$s,').join()}');
      case _Cmd.status:
        _sendStatus(now);
      case _Cmd.modeSettings:
        final List<String> pairs = <String>[
          for (int m = 0; m < EbDeviceModel._numModes; m++)
            '${scene.speeds[m]},${scene.frequencies[m]}',
        ];
        _rig.sendLine('MODE_SETTINGS:${pairs.join(';')}');
      case _Cmd.modeCapabilities:
        _rig.sendLine(_capabilities(a[0]));
      case _Cmd.sleep:
        timerActive = false;
        if (!sleeping) _sound('Sleep');
        _sleep(EbDeviceModel._sleepFadeMs);
        _rig.sendLine('OK');
      case _Cmd.wake:
        if (sleeping) _sound('Wake');
        _wake();
        _publish();
        _rig.sendLine('OK');
      case _Cmd.soundOn:
        soundEnabled = true;
        _checkStorage(_rig.store.saveSettings(soundEnabled: true, now: now));
        _rig.sounds.add('SoundOn'); // always audible
        _rig.sendLine('OK');
      case _Cmd.soundOff:
        soundEnabled = false;
        _checkStorage(_rig.store.saveSettings(soundEnabled: false, now: now));
        _rig.sendLine('OK');
      case _Cmd.timer:
        if (a[0] == 0) {
          if (timerActive) _sound('TimerCancel');
          timerActive = false;
        } else {
          timerActive = true;
          _timerDeadline = now + a[0] * 1000;
          _sound('TimerSet');
        }
        _rig.sendLine('OK');
      case _Cmd.factoryReset:
        _checkStorage(_rig.store.factoryReset());
        scene = EbScene.defaults(_rig.fixture.layout);
        soundEnabled = true;
        timerActive = false;
        _wake();
        _publish();
        _sound('FactoryReset');
        _rig.sendLine('OK');
      case _Cmd.info:
        _rig.sendLine('INFO:${_rig.fixture.modelId}');
      case _Cmd.version:
        _rig.sendLine('VERSION:${_rig.device.runningVersion}');
      case _Cmd.caps:
        _rig.sendLine(_rig.device.capsReply);
      case _Cmd.ping:
        _rig.sendLine('OK');
      case _Cmd.diag:
        _sendDiag(now);
      case _Cmd.identify:
        if (_setup) {
          // No LED output is known yet: the buzzer only, whatever the mute.
          _rig.sounds.add('Identify');
          _rig.sendLine('OK');
          return;
        }
        // Flashes over whatever the light shows (even asleep), then resumes;
        // no state change, nothing persisted, no Sleep/Wake sounds.
        _identifySeq = (_identifySeq + 1) & 0xFFFF;
        if (_identifySeq == 0) _identifySeq = 1;
        _identifying = true;
        _identifyAt = now;
        _publish();
        _sound('Identify');
        _rig.sendLine('OK');
      case _Cmd.setType:
        _setType(EbFixtureCatalog.all[a[0]]);
      case _Cmd.probe:
        // One output at a time; nothing persists, the state is untouched.
        if (a[1] == 1) {
          _probe = a[0] + 1;
          _probeDeadline = now + EbDeviceModel._probeMs;
        } else if (_probe == a[0] + 1) {
          _probe = 0;
        }
        _publish();
        _rig.sendLine('OK');
    }
  }

  static bool _allowedInSetup(_Cmd id) => switch (id) {
    _Cmd.caps ||
    _Cmd.version ||
    _Cmd.diag ||
    _Cmd.probe ||
    _Cmd.identify ||
    _Cmd.setType => true,
    _ => false,
  };

  /// ControllerCore::setType: clear the old layout's data, then store the
  /// type, reply and restart as the new type.
  void _setType(EbFixtureSpec type) {
    if (identical(type, _rig.fixture)) {
      _rig.sendLine('OK');
      return;
    }
    if (!_rig.store.clearForTypeChange()) {
      _reportError('STORAGE');
      return;
    }
    _rig.device._flash.type = type;
    _rig.stats.nvsWrites++;
    _restartPending = true;
    _rig.sendLine('OK');
    _rig.restartRequested = true;
  }

  static const List<(bool, bool, bool)> _modeCaps = <(bool, bool, bool)>[
    (false, false, false), // 1 Solid Color
    (false, true, false), // 2 Blink
    (true, true, false), // 3 Breath
    (true, true, true), // 4 Fireworks
    (true, true, false), // 5 TV Simulator
    (true, true, false), // 6 Thunderstorm
    (true, true, false), // 7 Faulty Bulb
    (true, true, false), // 8 Welding
    (true, true, true), // 9 Club Lights
    (false, true, false), // 10 Rainbow
    (true, true, false), // 11 Fire
    (true, true, true), // 12 Police Strobe
    (true, true, false), // 13 Candle
  ];

  String _capabilities(int mode) {
    final (bool speed, bool freq, bool colorMode) = _modeCaps[mode - 1];
    if (!speed && !freq) return 'CAPABILITIES:NONE';
    return 'CAPABILITIES:${speed ? 'SPEED' : ''}${speed && freq ? ',' : ''}'
        '${freq ? 'FREQUENCY' : ''}${colorMode ? ',COLOR_MODE' : ''}';
  }

  void _reportError(String code) {
    _rig.sendLine('ERROR:$code');
    _sound('Error');
  }

  void _sound(String id) {
    if (soundEnabled) _rig.sounds.add(id);
  }

  void _publish() => _rig.params = _Params(
    scene,
    sleeping: sleeping,
    fadeMs: _fadeMs,
    identifyId: _identifying ? _identifySeq : 0,
    identifyAt: _identifyAt,
    probe: _probe,
    ota: _otaBusy,
  );

  void _sceneChanged(int now) => _rig.store.noteSceneChanged(now);

  void _wake() {
    if (sleeping) {
      sleeping = false;
      _fadeMs = EbDeviceModel._sleepFadeMs;
    }
  }

  void _sleep(int fadeMs) {
    sleeping = true;
    _fadeMs = fadeMs;
    _publish();
  }

  void _sendStatus(int now) {
    final EbScene s = scene;
    final List<int> v = <int>[
      ...s.color.values,
      s.brightness,
      s.mode,
      s.speed,
      s.frequency,
      s.fireworkColorMode,
      s.clubColorMode,
      s.policeColorMode,
      if (sleeping) 1 else 0,
      if (timerActive) 1 else 0,
      timerRemainingSec(now),
      if (soundEnabled) 1 else 0,
      ...s.policeA.values,
      ...s.policeB.values,
    ];
    _rig.sendLine('STATUS:${v.join(',')}');
  }

  void _sendDiag(int now) {
    final _Stats st = _rig.stats;
    // Render statistics are not simulated (fwsim has no render task either);
    // system values match SimDevice::Env::systemDiag.
    final List<(String, int)> kv = <(String, int)>[
      ('rx', st.rxLines),
      ('ovf', st.rxLineOverflows),
      ('rej', st.rxRejectedBytes),
      ('sdrop', st.rxStreamDrops),
      ('unk', st.unknownCommands),
      ('err', st.commandErrors),
      ('coal', st.coalesced),
      ('bin', st.binaryOk),
      ('binbad', st.binaryBad),
      ('gaps', st.binarySeqGaps),
      ('nretry', st.notifyRetries),
      ('edrop', st.egressDrops),
      ('nvsw', st.nvsWrites),
      ('nvsf', st.nvsFailures),
      ('frames', 0),
      ('overrun', 0),
      ('rmaxus', 0),
      ('heapmin', 180000),
      ('stkc', 3000),
      ('stkr', 2000),
      ('rst', 1),
      ('up', now ~/ 1000),
      ('slot', _rig.device.otaFlash.running),
      ('rb', _rig.device.otaFlash.rolledBack ? 1 : 0),
      ('pv', _rig.device.otaFlash.pendingVerify ? 1 : 0),
      ('endms', _rig.device._flash.finishMs ?? 0),
    ];
    _rig.sendLine(
      'DIAG:${kv.map(((String, int) e) => '${e.$1}=${e.$2}').join(',')}',
    );
  }

  void _checkStorage(bool ok) {
    if (ok || _storageErrorReported) return;
    _storageErrorReported = true;
    _reportError('STORAGE');
  }
}
