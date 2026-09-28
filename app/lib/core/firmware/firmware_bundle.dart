import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../util/sha256.dart';

/// A firmware version "major.minor.patch" (the firmware's `kFirmwareVersion`
/// and VERSION reply).
@immutable
final class FirmwareVersion implements Comparable<FirmwareVersion> {
  const FirmwareVersion(this.major, this.minor, this.patch);

  /// Null unless [text] is exactly three numbers of at most 16 bits.
  static FirmwareVersion? tryParse(String? text) {
    if (text == null) return null;
    final RegExpMatch? m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(text);
    if (m == null) return null;
    final List<int> v = <int>[for (int i = 1; i <= 3; i++) int.parse(m[i]!)];
    if (v.any((int x) => x > 0xFFFF)) return null;
    return FirmwareVersion(v[0], v[1], v[2]);
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(FirmwareVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(FirmwareVersion other) => compareTo(other) < 0;
  bool operator >(FirmwareVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is FirmwareVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;
  @override
  int get hashCode => Object.hash(major, minor, patch);
  @override
  String toString() => '$major.$minor.$patch';
}

/// assets/firmware/manifest.json: what `tool/bundle_firmware.sh` bundled.
@immutable
final class FirmwareManifest {
  const FirmwareManifest({
    required this.version,
    required this.size,
    required this.sha256,
    required this.file,
    this.product = productName,
    this.kind = universalKind,
    this.rollbackTest = 0,
  });

  static const String productName = 'ElectroBright';

  /// The only image kind lights accept over the air.
  static const String universalKind = 'universal';

  final FirmwareVersion version;
  final int size;

  /// Lower-case hex.
  final String sha256;

  /// The image's file name next to the manifest.
  final String file;
  final String product;
  final String kind;

  /// 0, or a rollback test image (1 fails its self-check, 2 freezes): the
  /// identity block's mark (firmware 3.8.1 test builds).
  final int rollbackTest;

  /// Strict: null when a field is missing or malformed, or the image is not
  /// an ElectroBright universal image.
  static FirmwareManifest? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final FirmwareVersion? version = FirmwareVersion.tryParse(
      json['version'] is String ? json['version']! as String : null,
    );
    final Object? size = json['size'];
    final Object? sha = json['sha256'];
    final Object? file = json['file'];
    final Object test = json['rollbackTest'] ?? 0;
    if (version == null ||
        test is! int ||
        test < 0 ||
        test > 2 ||
        size is! int ||
        size <= 0 ||
        sha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
        file is! String ||
        file.isEmpty ||
        file.contains('/') ||
        json['product'] != productName ||
        json['kind'] != universalKind) {
      return null;
    }
    return FirmwareManifest(
      version: version,
      size: size,
      sha256: sha,
      file: file,
      rollbackTest: test,
    );
  }
}

/// A firmware image ready to send: its bytes, version and SHA-256.
@immutable
final class FirmwareImage {
  FirmwareImage({required this.bytes, required this.version})
    : sha256 = Sha256.of(bytes);

  final Uint8List bytes;
  final FirmwareVersion version;
  final Uint8List sha256;

  int get size => bytes.length;
}

/// The firmware image bundled with the app (assets/firmware/): its manifest,
/// read when the app starts, and the image, loaded and checked when an update
/// begins.
final class FirmwareBundle {
  FirmwareBundle(this.manifest, this._load);

  static const String directory = 'assets/firmware';
  static const String manifestPath = '$directory/manifest.json';

  final FirmwareManifest manifest;
  final Future<ByteData> Function() _load;
  FirmwareImage? _image;

  FirmwareVersion get version => manifest.version;

  /// The bundle read through [text] and [bytes] (the app's asset bundle), or
  /// null when the app has none (or a malformed manifest).
  static Future<FirmwareBundle?> load({
    required Future<String> Function(String path) text,
    required Future<ByteData> Function(String path) bytes,
  }) async {
    final FirmwareManifest? m;
    try {
      m = FirmwareManifest.fromJson(jsonDecode(await text(manifestPath)));
    } on Object {
      return null;
    }
    if (m == null) return null;
    return FirmwareBundle(m, () => bytes('$directory/${m!.file}'));
  }

  /// The image, checked against the manifest (size and SHA-256). Throws
  /// [StateError] when it does not match.
  Future<FirmwareImage> image() async {
    final FirmwareImage? cached = _image;
    if (cached != null) return cached;
    final ByteData data = await _load();
    final FirmwareImage img = FirmwareImage(
      bytes: Uint8List.sublistView(data),
      version: manifest.version,
    );
    if (img.size != manifest.size || hex(img.sha256) != manifest.sha256) {
      throw StateError('the bundled firmware does not match its manifest');
    }
    return _image = img;
  }

  static String hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}
