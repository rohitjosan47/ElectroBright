import 'dart:typed_data';

import '../core/model/rgbw.dart';
import '../core/protocol/eb/eb_scene.dart';

/// Dart twin of the ElectroBright firmware (v3.4.0): the command parser,
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
  EbDeviceModel() {
    _rig = _Rig(this);
    boot();
  }

  /// Makes flash writes fail (like fwsim `KVFAIL`), for fault tests.
  set flashWritesFail(bool fail) => _flash.failWrites = fail;

  static const String firmwareVersion = '3.4.0';
  static const String modelId = 'EB-C3-RGBW-V1';
  static const String capsReply =
      'CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL';

  // cfg (Config.h)
  static const int _numModes = 13;
  static const int _numPresets = 25;
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
  void boot() => _rig.core.begin(_now);

  /// Power cycle: RAM state is lost, flash survives, the link drops.
  void reboot() {
    _rig = _Rig(this);
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
    _delivered.clear();
    _now += 1500;
    boot();
  }

  // ---- Radio (BleNus.cpp) ----------------------------------------------------------
  void connect() {
    _mtu = 23;
    _connected = true;
    _subscribed = false;
    _events.add(1);
  }

  void disconnect() {
    _connected = false;
    _subscribed = false;
    _events.add(2);
  }

  void setMtu(int mtu) => _mtu = mtu;
  void setSubscribed({required bool subscribed}) => _subscribed = subscribed;
  void failNextNotifies(int count) => _notifyFailures = count;

  void write(List<int> data) {
    if (data.isEmpty) return;
    if (_isFrameCandidate(data)) {
      final _ColorFrame? frame = _decodeFrame(data);
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

    final _AssemblerCounters c = _assembler.counters;
    _rig.stats.rxLineOverflows += c.overflows - _seen.overflows;
    _rig.stats.rxRejectedBytes += c.rejected - _seen.rejected;
    _seen = c;

    _rig.core.tick(_now);

    if (_connected) {
      final int before = _egress.retries;
      _egress.flush(_maxPayload, _notify);
      _rig.stats.notifyRetries += _egress.retries - before;
    } else {
      _egress.clear();
    }
  }

  void pass() {
    passBegin();
    passEnd();
  }

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

  /// Same shape as fwsim's `STATE` reply.
  Map<String, Object> state() {
    final EbScene s = _rig.core.scene;
    final _Stats st = _rig.stats;
    return <String, Object>{
      'scene': <String, Object>{
        'color': s.color.toList(),
        'brightness': s.brightness,
        'mode': s.mode,
        'speed': s.speeds,
        'freq': s.frequencies,
        'fireworkColorMode': s.fireworkColorMode,
        'clubColorMode': s.clubColorMode,
        'policeColorMode': s.policeColorMode,
        'policeA': s.policeA.toList(),
        'policeB': s.policeB.toList(),
      },
      'sleeping': _rig.core.sleeping ? 1 : 0,
      'timer': <String, Object>{
        'active': _rig.core.timerActive ? 1 : 0,
        'remaining': _rig.core.timerRemainingSec(_now),
      },
      'sound': _rig.core.soundEnabled ? 1 : 0,
      'presets': (_rig.store.presetSlots.toList()..sort()),
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
  _Params(this.scene, {required this.sleeping, required this.fadeMs});
  final EbScene scene;
  final bool sleeping;
  final int fadeMs;
}

/// Everything a reboot recreates (flash lives in [EbDeviceModel.flash]).
final class _Rig {
  _Rig(this.device) {
    store = _StateStore(device._flash, stats);
    core = _Controller(this);
  }
  final EbDeviceModel device;
  final _Stats stats = _Stats();
  final List<String> sounds = <String>[];
  _Params params = _Params(EbScene.defaults(), sleeping: false, fadeMs: 400);
  late final _StateStore store;
  late final _Controller core;

  void sendLine(String line) {
    if (!device._egress.push(line)) stats.egressDrops++;
  }
}

// ---- BinaryFrame.cpp -------------------------------------------------------------------
final class _ColorFrame {
  const _ColorFrame(this.color, this.brightness, this.seq);
  final Rgbw color;
  final int? brightness;
  final int? seq;
}

bool _isFrameCandidate(List<int> d) =>
    d.length >= 6 && d.length <= 8 && d[0] == 0xAA;

_ColorFrame? _decodeFrame(List<int> d) {
  if (!_isFrameCandidate(d)) return null;
  if (d.length == 8) {
    final int sum = d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ 0x55;
    if (sum != d[7]) return null;
    return _ColorFrame(Rgbw(d[2], d[3], d[4], d[5]), d[6], d[1]);
  }
  if (d.length == 7) {
    final int sum = d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ 0x55;
    if (sum != d[6]) return null;
    return _ColorFrame(Rgbw(d[1], d[2], d[3], d[4]), d[5], null);
  }
  final int sum = d[1] ^ d[2] ^ d[3] ^ d[4] ^ 0x55;
  if (sum != d[5]) return null;
  return _ColorFrame(Rgbw(d[1], d[2], d[3], d[4]), null, null);
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
  EbScene? scene;
  bool? soundEnabled;
  final Map<int, EbScene> presets = <int, EbScene>{};
  bool failWrites = false;
}

final class _StateStore {
  _StateStore(this.kv, this.stats);
  final _Flash kv;
  final _Stats stats;
  EbScene? _shadow;
  bool _dirty = false;
  int _firstDirty = 0;
  int _lastDirty = 0;
  final Set<int> presetSlots = <int>{};

  bool _noteWrite(bool ok) {
    if (ok) {
      stats.nvsWrites++;
    } else {
      stats.nvsFailures++;
    }
    return ok;
  }

  (EbScene, bool) load() {
    final EbScene scene;
    if (kv.scene != null) {
      scene = kv.scene!;
      _shadow = kv.scene;
    } else {
      scene = EbScene.defaults();
      _shadow = null;
    }
    final bool sound = kv.soundEnabled ?? true;
    presetSlots
      ..clear()
      ..addAll(kv.presets.keys);
    _dirty = false;
    return (scene, sound);
  }

  void noteSceneChanged(int now) {
    if (!_dirty) _firstDirty = now;
    _dirty = true;
    _lastDirty = now;
  }

  bool tick(int now, EbScene scene) {
    if (!_dirty) return true;
    final bool quiet = now - _lastDirty >= EbDeviceModel._persistDebounceMs;
    final bool overdue =
        now - _firstDirty >= EbDeviceModel._persistMaxLatencyMs;
    if (!quiet && !overdue) return true;
    return _flush(scene);
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

  bool saveSettings({required bool soundEnabled}) {
    final bool ok = !kv.failWrites;
    if (ok) kv.soundEnabled = soundEnabled;
    return _noteWrite(ok);
  }

  bool savePreset(int id, EbScene scene) {
    if (id >= EbDeviceModel._numPresets) return false;
    if (!_noteWrite(!kv.failWrites)) return false;
    kv.presets[id] = scene;
    presetSlots.add(id);
    return true;
  }

  EbScene? loadPreset(int id) {
    if (id >= EbDeviceModel._numPresets) return null;
    final EbScene? s = kv.presets[id];
    if (s != null) {
      presetSlots.add(id);
    } else {
      presetSlots.remove(id);
    }
    return s;
  }

  bool deletePreset(int id) {
    if (id >= EbDeviceModel._numPresets) return false;
    final bool ok = !kv.failWrites;
    if (ok) {
      kv.presets.remove(id);
      presetSlots.remove(id);
    }
    return _noteWrite(ok);
  }

  bool factoryReset() {
    final bool ok = _noteWrite(!kv.failWrites);
    if (ok) {
      kv
        ..scene = null
        ..soundEnabled = null
        ..presets.clear();
    }
    presetSlots.clear();
    _shadow = null;
    _dirty = false;
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
];

enum _ParseStatus { ok, unknown, format, range }

final class _Parsed {
  const _Parsed.ok(this.id, this.args) : status = _ParseStatus.ok, error = null;
  const _Parsed.fail(this.status, this.error) : id = null, args = const <int>[];
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

_Parsed _parseCommand(String line) {
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

  final int args = colon != null ? colon + 1 : end;
  int p = args;
  while (p < end && _isSpace(line.codeUnitAt(p))) {
    p++;
  }
  final bool noArgText = p == end;

  if (spec.argc == 0) {
    return noArgText
        ? _Parsed.ok(spec.id, const <int>[])
        : _Parsed.fail(_ParseStatus.format, spec.error);
  }
  if (colon == null || noArgText) {
    return _Parsed.fail(_ParseStatus.format, spec.error);
  }

  final List<int> values = <int>[];
  int fieldStart = args;
  for (int q = args; ; q++) {
    if (q == end || line.codeUnitAt(q) == 0x2C) {
      if (values.length == spec.argc) {
        int t = fieldStart;
        while (t < q && _isSpace(line.codeUnitAt(t))) {
          t++;
        }
        if (t != q || q != end) {
          return _Parsed.fail(_ParseStatus.format, spec.error);
        }
        break;
      }
      final (int rc, int v) = _parseField(line, fieldStart, q);
      if (rc == 1) return _Parsed.fail(_ParseStatus.format, spec.error);
      final bool first = values.isEmpty;
      final int lo = first ? spec.firstMin : spec.restMin;
      final int hi = first ? spec.firstMax : spec.restMax;
      if (rc == 2 || v < lo || v > hi) {
        return _Parsed.fail(_ParseStatus.range, spec.error);
      }
      values.add(v);
      if (q == end) break;
      fieldStart = q + 1;
    }
  }
  if (values.length != spec.argc) {
    return _Parsed.fail(_ParseStatus.format, spec.error);
  }
  return _Parsed.ok(spec.id, values);
}

bool _isCoalescible(_Cmd id) =>
    id == _Cmd.rgbw ||
    id == _Cmd.brightness ||
    id == _Cmd.speed ||
    id == _Cmd.frequency;

// ---- ControllerCore.cpp + Replies.cpp -----------------------------------------------------
final class _Controller {
  _Controller(this._rig);
  final _Rig _rig;

  EbScene scene = EbScene.defaults();
  bool soundEnabled = true;
  bool sleeping = false;
  int _fadeMs = EbDeviceModel._sleepFadeMs;
  bool timerActive = false;
  int _timerDeadline = 0;
  bool _haveSeq = false;
  int _expectedSeq = 0;
  bool _storageErrorReported = false;

  void begin(int now) {
    final (EbScene s, bool sound) = _rig.store.load();
    scene = s;
    soundEnabled = sound;
    sleeping = false;
    timerActive = false;
    _fadeMs = EbDeviceModel._sleepFadeMs;
    _publish();
    _sound('Boot');
  }

  void onConnect() => _haveSeq = false;

  void onDisconnect() => _haveSeq = false;

  void tick(int now) {
    if (timerActive && now - _timerDeadline >= 0) {
      timerActive = false;
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
    final int? seq = f.seq;
    if (seq != null) {
      if (_haveSeq && seq != _expectedSeq) _rig.stats.binarySeqGaps++;
      _haveSeq = true;
      _expectedSeq = (seq + 1) & 0xFF;
    }
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
        for (int k = 0; k < n; k++) _parseCommand(lines[i + k]),
      ];
      for (int k = 0; k < n; k++) {
        _rig.stats.rxLines++;
        final _Parsed r = results[k];
        if (r.status == _ParseStatus.unknown) {
          _rig.stats.unknownCommands++;
          _reportError(r.error!);
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
    switch (id) {
      case _Cmd.rgbw:
        scene = scene.copyWith(color: Rgbw(a[0], a[1], a[2], a[3]));
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
        scene = scene.copyWith(policeA: Rgbw(a[0], a[1], a[2], a[3]));
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.policeColorB:
        scene = scene.copyWith(policeB: Rgbw(a[0], a[1], a[2], a[3]));
        _sceneChanged(now);
        _publish();
        _rig.sendLine('OK');
      case _Cmd.presetSave:
        if (_rig.store.savePreset(a[0], scene)) {
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
        if (_rig.store.deletePreset(a[0])) {
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
        _checkStorage(_rig.store.saveSettings(soundEnabled: true));
        _rig.sounds.add('SoundOn'); // always audible
        _rig.sendLine('OK');
      case _Cmd.soundOff:
        soundEnabled = false;
        _checkStorage(_rig.store.saveSettings(soundEnabled: false));
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
        scene = EbScene.defaults();
        soundEnabled = true;
        timerActive = false;
        _wake();
        _publish();
        _sound('FactoryReset');
        _rig.sendLine('OK');
      case _Cmd.info:
        _rig.sendLine('INFO:${EbDeviceModel.modelId}');
      case _Cmd.version:
        _rig.sendLine('VERSION:${EbDeviceModel.firmwareVersion}');
      case _Cmd.caps:
        _rig.sendLine(EbDeviceModel.capsReply);
      case _Cmd.ping:
        _rig.sendLine('OK');
      case _Cmd.diag:
        _sendDiag(now);
    }
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

  void _publish() =>
      _rig.params = _Params(scene, sleeping: sleeping, fadeMs: _fadeMs);

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
      ...s.color.toList(),
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
      ...s.policeA.toList(),
      ...s.policeB.toList(),
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
