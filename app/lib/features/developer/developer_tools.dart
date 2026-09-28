import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';

/// Settings → Advanced → Developer tools (off by default, kept in the app's
/// main settings for real and demo lights alike). When on, Settings and each
/// light's settings have a Developer row; when off, nothing of it shows.
final NotifierProvider<DeveloperToolsNotifier, bool> developerToolsProvider =
    NotifierProvider<DeveloperToolsNotifier, bool>(DeveloperToolsNotifier.new);

final class DeveloperToolsNotifier extends Notifier<bool> {
  static const String key = 'developerTools';

  @override
  bool build() {
    final Object? v = ref.read(storeProvider).read('settings');
    return v is Map<String, Object?> && v[key] == true;
  }

  void set({required bool on}) {
    final Object? v = ref.read(storeProvider).read('settings');
    final Map<String, Object?> settings = v is Map<String, Object?>
        ? Map<String, Object?>.of(v)
        : <String, Object?>{};
    if (on) {
      settings[key] = true;
    } else {
      settings.remove(key);
    }
    ref.read(storeProvider).write('settings', settings);
    state = on;
  }
}
