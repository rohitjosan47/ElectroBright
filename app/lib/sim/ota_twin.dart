import 'dart:typed_data';

import '../core/protocol/eb/eb_ota.dart';
import '../core/util/sha256.dart';

/// Dart twin of the firmware's wireless-update side, ported line for line:
/// ota/ImageIdentity.cpp, ota/OtaReceiver.cpp, ota/OtaReplies.h,
/// ota/SelfCheck.h and the fake flash with the bootloader's rollback rules
/// (firmware/test/Fakes.h MockOtaFlash). The OTA differential test
/// (test/fw_in_the_loop/ota_differential_test.dart) keeps it equal to fwsim.

/// ImageIdentity.h: the 64-byte identity block of an ElectroBright image.
abstract final class ImageIdentityTwin {
  static const List<int> magic = <int>[
    0x45,
    0x42,
    0x49,
    0x4D,
    0x47,
    0x49,
    0x44,
    0x31,
  ]; // EBIMGID1
  static const String product = 'ElectroBright';
  static const String kind = 'universal';
  static const int size = 64;
  static const int searchBytes = 1024;

  /// The block as the firmware lays it out: magic, product[16], kind[12],
  /// version[16], reserved[12].
  static Uint8List build({
    required String version,
    String productName = product,
    String kindName = kind,
  }) {
    final Uint8List b = Uint8List(size);
    b.setAll(0, magic);
    void field(int at, int len, String text) {
      final List<int> t = text.codeUnits.take(len - 1).toList();
      b.setAll(at, t);
    }

    field(8, 16, productName);
    field(24, 12, kindName);
    field(36, 16, version);
    return b;
  }

  /// imageid::find: the block's offset in the image head, or null.
  static int? find(List<int> image) {
    final int end = image.length < searchBytes ? image.length : searchBytes;
    for (int off = 0; off + size <= end; off += 4) {
      bool match = true;
      for (int i = 0; i < magic.length && match; i++) {
        match = image[off + i] == magic[i];
      }
      if (match) return off;
    }
    return null;
  }

  static String? _field(List<int> image, int at, int len) {
    final int nul = image.sublist(at, at + len).indexOf(0);
    if (nul < 0) return null;
    return String.fromCharCodes(image.sublist(at, at + nul));
  }

  /// imageid::isUniversal + the version it names (null: not universal).
  static List<int>? universalVersion(List<int> image, int at) {
    if (_field(image, at + 8, 16) != product) return null;
    if (_field(image, at + 24, 12) != kind) return null;
    final String? v = _field(image, at + 36, 16);
    return v == null ? null : parseVersion(v);
  }

  /// imageid::parseVersion: "3.8.0" -> [3, 8, 0].
  static List<int>? parseVersion(String text) {
    final RegExpMatch? m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(text);
    if (m == null) return null;
    final List<int> v = <int>[
      for (int i = 1; i <= 3; i++) int.parse(m.group(i)!),
    ];
    return v.any((int x) => x > 65535) ? null : v;
  }

  static int compare(List<int> a, List<int> b) {
    for (int i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
  }
}

/// IOtaFlash::Status.
enum OtaFlashStatus { ok, busy, invalid, error }

/// The rollback state of an OTA app slot.
enum OtaSlotState { valid, fresh, pendingVerify, aborted, invalid }

/// Two OTA app slots in memory plus the bootloader's rollback rules
/// (firmware/test/Fakes.h MockOtaFlash).
final class SimOtaFlash {
  int capacity = 0x140000;
  final List<List<int>> slot = <List<int>>[<int>[], <int>[]];
  final List<OtaSlotState> state = <OtaSlotState>[
    OtaSlotState.valid,
    OtaSlotState.valid,
  ];
  int running = 0;
  int boot = 0;
  bool open = false;
  bool failWrites = false;
  bool forceInvalid = false;

  int get spare => 1 - running;
  int spareSize() => capacity;

  OtaFlashStatus begin() {
    if (state[running] == OtaSlotState.pendingVerify) {
      return OtaFlashStatus.busy;
    }
    slot[spare].clear();
    open = true;
    return OtaFlashStatus.ok;
  }

  OtaFlashStatus resume(int offset) {
    if (state[running] == OtaSlotState.pendingVerify) {
      return OtaFlashStatus.busy;
    }
    if (offset > slot[spare].length) return OtaFlashStatus.error;
    slot[spare].length = offset;
    open = true;
    return OtaFlashStatus.ok;
  }

  bool write(List<int> data) {
    if (!open || failWrites || slot[spare].length + data.length > capacity) {
      return false;
    }
    slot[spare].addAll(data);
    return true;
  }

  OtaFlashStatus finish() {
    if (!open) return OtaFlashStatus.error;
    open = false;
    final List<int> img = slot[spare];
    return img.isNotEmpty && img[0] == 0xE9 && !forceInvalid
        ? OtaFlashStatus.ok
        : OtaFlashStatus.invalid;
  }

  void abort() => open = false;

  List<int>? read(int offset, int len) {
    final List<int> img = slot[spare];
    if (offset + len > img.length) return null;
    return img.sublist(offset, offset + len);
  }

  bool setBoot() {
    boot = spare;
    state[boot] = OtaSlotState.fresh;
    return true;
  }

  /// A restart: the bootloader picks the slot to run.
  void bootloader() {
    open = false;
    if (state[boot] == OtaSlotState.fresh) {
      state[boot] = OtaSlotState.pendingVerify;
    } else if (state[boot] == OtaSlotState.pendingVerify) {
      state[boot] = OtaSlotState.aborted; // never confirmed: roll back
      boot = 1 - boot;
    }
    running = boot;
  }

  bool get pendingVerify => state[running] == OtaSlotState.pendingVerify;
  void confirm() => state[running] = OtaSlotState.valid;
  void markInvalid() {
    state[running] = OtaSlotState.invalid;
    boot = 1 - running;
  }

  bool get rolledBack => state.any(
    (OtaSlotState s) => s == OtaSlotState.aborted || s == OtaSlotState.invalid,
  );
}

/// ota/OtaReplies.h: replies waiting for the control characteristic.
final class OtaRepliesTwin {
  static const int capacity = 8;
  static const int maxLen = 12;
  final List<List<int>> _q = <List<int>>[];

  void push(List<int> data) {
    if (_q.length == capacity) _q.removeAt(0);
    _q.add(data.length > maxLen ? data.sublist(0, maxLen) : data);
  }

  bool get isEmpty => _q.isEmpty;
  void clear() => _q.clear();

  void flush(bool Function(List<int> data) send) {
    while (_q.isNotEmpty) {
      if (!send(_q.first)) return;
      _q.removeAt(0);
    }
  }
}

/// ota/SelfCheck.h.
abstract final class SelfCheckTwin {
  static const int deadlineMs = 15000;
  static const int minRenderFrames = 400;
}

/// ota/OtaReceiver.cpp.
final class OtaReceiverTwin {
  OtaReceiverTwin({
    required this.flash,
    required this.running,
    required this.reply,
    required this.onActive,
    required this.onRestart,
  });

  final SimOtaFlash flash;
  final List<int> running;
  final void Function(List<int> data) reply;
  final void Function(bool active) onActive;
  final void Function() onRestart;

  bool active = false;
  bool restarting = false;
  bool blocked = false;
  int _size = 0;
  List<int> _hash = const <int>[];
  List<int> _version = const <int>[0, 0, 0];
  int _next = 0;
  Sha256 _sha = Sha256();
  int _lastData = 0;
  bool _outOfOrderReported = false;
  int ignoredChunks = 0;

  // Resume point.
  bool _resumeValid = false;
  int _resumeSize = 0;
  List<int> _resumeHash = const <int>[];
  List<int> _resumeVersion = const <int>[0, 0, 0];
  int _resumeNext = 0;
  Sha256 _resumeSha = Sha256();

  int get next => active ? _next : 0;
  int get size => active ? _size : 0;
  int get imageSize => _size;
  bool get canResume => _resumeValid;

  static int _u32(List<int> p, int at) =>
      p[at] | (p[at + 1] << 8) | (p[at + 2] << 16) | (p[at + 3] << 24);
  static List<int> _le32(int v) => <int>[
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];
  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _same(
    int size,
    List<int> hash,
    List<int> version,
    int s2,
    List<int> h2,
    List<int> v2,
  ) =>
      size == s2 &&
      _sameBytes(hash, h2) &&
      ImageIdentityTwin.compare(version, v2) == 0;

  void onControl(List<int> d, int now) {
    if (d.isEmpty) return _error(EbOtaError.badRequest);
    switch (d[0]) {
      case EbOta.begin:
        return _begin(d, now);
      case EbOta.end:
        if (d.length != 1) return _error(EbOtaError.badRequest);
        return _end();
      case EbOta.abort:
        if (d.length != 1) return _error(EbOtaError.badRequest);
        return _abort();
      case EbOta.status:
        if (d.length != 1) return _error(EbOtaError.badRequest);
        return _state();
      default:
        return _error(EbOtaError.badRequest);
    }
  }

  void onData(List<int> d, int now) {
    if (!active || d.length <= EbOta.dataHeader) {
      ignoredChunks++;
      return;
    }
    _lastData = now;
    final int offset = _u32(d, 0);
    final List<int> payload = d.sublist(EbOta.dataHeader);
    final int n = payload.length;
    if (offset != _next) {
      ignoredChunks++;
      if (!_outOfOrderReported) {
        _outOfOrderReported = true;
        _ack();
      }
      return;
    }
    if (n > _size - _next) {
      _error(EbOtaError.badSize);
      return _stop(keepResume: false);
    }
    if (!flash.write(payload)) {
      _error(EbOtaError.flashError);
      return _stop(keepResume: false);
    }
    _sha.update(payload);
    final int before = _next;
    _next += n;
    _outOfOrderReported = false;
    if (_next ~/ EbOta.window != before ~/ EbOta.window || _next == _size) {
      _ack();
    }
  }

  void tick(int now) {
    if (!active || ((now - _lastData) & 0xFFFFFFFF) < EbOta.timeoutMs) return;
    _stop(keepResume: true);
    _error(EbOtaError.timeout);
  }

  void _beginOk() => reply(<int>[
    EbOta.beginOk,
    ..._le32(_next),
    EbOta.window & 0xFF,
    (EbOta.window >> 8) & 0xFF,
  ]);

  void _begin(List<int> d, int now) {
    if (d.length != EbOta.beginLength) return _error(EbOtaError.badRequest);
    final int size = _u32(d, 1);
    final List<int> hash = d.sublist(5, 37);
    final List<int> version = <int>[
      d[37] | (d[38] << 8),
      d[39] | (d[40] << 8),
      d[41] | (d[42] << 8),
    ];
    final bool reinstall = (d[43] & EbOta.flagReinstall) != 0;

    if (restarting || blocked) return _error(EbOtaError.busy);
    if (active) {
      if (!_same(size, hash, version, _size, _hash, _version)) {
        return _error(EbOtaError.busy);
      }
      _lastData = now;
      _outOfOrderReported = false;
      return _beginOk();
    }
    if (size == 0 || size > flash.spareSize()) {
      return _error(EbOtaError.badSize);
    }
    final int order = ImageIdentityTwin.compare(version, running);
    if (order < 0) return _error(EbOtaError.downgrade);
    if (order == 0 && !reinstall) return _error(EbOtaError.sameVersion);

    OtaFlashStatus st;
    if (_resumeValid &&
        _same(_resumeSize, _resumeHash, _resumeVersion, size, hash, version)) {
      st = flash.resume(_resumeNext);
      if (st == OtaFlashStatus.ok) {
        _next = _resumeNext;
        _sha = _resumeSha.copy();
      }
    } else {
      _resumeValid = false;
      st = flash.begin();
      _next = 0;
      _sha = Sha256();
    }
    if (st == OtaFlashStatus.busy) return _error(EbOtaError.busy);
    if (st != OtaFlashStatus.ok) {
      _resumeValid = false;
      return _error(EbOtaError.flashError);
    }
    _size = size;
    _hash = hash;
    _version = version;
    _resumeValid = false;
    active = true;
    _lastData = now;
    _outOfOrderReported = false;
    onActive(true);
    _beginOk();
  }

  void _end() {
    if (!active) {
      return _error(restarting ? EbOtaError.busy : EbOtaError.badRequest);
    }
    if (_next != _size) return _error(EbOtaError.incomplete);
    if (!_sameBytes(_sha.digest(), _hash)) {
      _error(EbOtaError.hashMismatch);
      return _stop(keepResume: false);
    }
    final OtaFlashStatus st = flash.finish();
    if (st != OtaFlashStatus.ok) {
      _error(
        st == OtaFlashStatus.invalid
            ? EbOtaError.notElectroBright
            : EbOtaError.flashError,
      );
      return _stop(keepResume: false);
    }
    final int headLen = _size < ImageIdentityTwin.searchBytes
        ? _size
        : ImageIdentityTwin.searchBytes;
    final List<int>? head = flash.read(0, headLen);
    if (head == null) {
      _error(EbOtaError.flashError);
      return _stop(keepResume: false);
    }
    final int? at = ImageIdentityTwin.find(head);
    final List<int>? v = at == null
        ? null
        : ImageIdentityTwin.universalVersion(head, at);
    if (v == null || ImageIdentityTwin.compare(v, _version) != 0) {
      _error(EbOtaError.notElectroBright);
      return _stop(keepResume: false);
    }
    if (!flash.setBoot()) {
      _error(EbOtaError.flashError);
      return _stop(keepResume: false);
    }
    active = false;
    restarting = true;
    reply(const <int>[EbOta.endOk]);
    onRestart();
  }

  void _abort() {
    if (active) {
      _stop(keepResume: false);
    } else {
      _resumeValid = false;
    }
    reply(const <int>[EbOta.aborted]);
  }

  void _stop({required bool keepResume}) {
    flash.abort();
    if (keepResume && _next > 0) {
      _resumeValid = true;
      _resumeSize = _size;
      _resumeHash = _hash;
      _resumeVersion = _version;
      _resumeNext = _next;
      _resumeSha = _sha.copy();
    } else {
      _resumeValid = false;
    }
    active = false;
    onActive(false);
  }

  void _error(EbOtaError code) =>
      reply(<int>[EbOta.error, code.code, ..._le32(active ? _next : 0)]);

  void _ack() => reply(<int>[EbOta.ack, ..._le32(_next)]);

  void _state() => reply(<int>[
    EbOta.state,
    restarting
        ? EbOta.stateRestarting
        : active
        ? EbOta.stateReceiving
        : EbOta.stateIdle,
    ..._le32(active ? _next : 0),
    ..._le32(active ? _size : 0),
  ]);
}
