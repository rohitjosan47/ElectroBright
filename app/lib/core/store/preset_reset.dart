import 'json_store.dart';

/// One-time drop of the app's preset data (names and snapshots in the
/// `presetMeta` collection) from before 15-slot firmware 3.6.0, which clears
/// the presets on the lights themselves once. Nothing is migrated.
abstract final class PresetReset {
  /// Set in the store's `settings` once done.
  static const String doneFlag = 'presets.v2';
  static const String collection = 'presetMeta';

  /// Empties `presetMeta` in [store] unless already done. True if it did.
  static bool run(JsonStore store) {
    final Object? saved = store.read('settings');
    final Map<String, Object?> settings = saved is Map<String, Object?>
        ? Map<String, Object?>.of(saved)
        : <String, Object?>{};
    if (settings[doneFlag] == true) return false;
    store.write(collection, <String, Object?>{});
    settings[doneFlag] = true;
    store.write('settings', settings);
    return true;
  }
}
