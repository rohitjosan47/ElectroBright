import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../../app/app_session.dart';
import '../../../core/protocol/eb/eb_scene.dart';
import '../../../core/store/json_store.dart';

/// What the app knows about one preset slot of a light: the name the user
/// gave it and the scene it holds (the light itself only stores the scene).
@immutable
final class PresetEntry {
  const PresetEntry({this.name, this.scene, this.assumed = false});

  final String? name;

  /// The slot's scene as last saved or loaded (for previews and "active").
  final EbScene? scene;

  /// Imported from the old app (RGBW assumed); replaced on the next load.
  final bool assumed;

  PresetEntry copyWith({String? name, EbScene? scene, bool? assumed}) =>
      PresetEntry(
        name: name ?? this.name,
        scene: scene ?? this.scene,
        assumed: assumed ?? this.assumed,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    if (name != null) 'name': name,
    if (scene != null) 'scene': scene!.toJson(),
    if (assumed) 'assumedLayout': true,
  };

  static PresetEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    return PresetEntry(
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      scene: EbScene.fromJson(json['scene']),
      assumed: json['assumedLayout'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PresetEntry &&
      other.name == name &&
      other.scene == scene &&
      other.assumed == assumed;

  @override
  int get hashCode => Object.hash(name, scene, assumed);
}

/// Preset names and snapshots of one light, plus which slot was loaded last
/// (for "Modified from …").
@immutable
final class PresetMeta {
  const PresetMeta(this.slots, {this.lastLoaded});
  final Map<int, PresetEntry> slots;
  final int? lastLoaded;

  static const PresetMeta empty = PresetMeta(<int, PresetEntry>{});

  PresetEntry? operator [](int slot) => slots[slot];

  /// The slot whose snapshot is exactly [scene] (preferring the one loaded
  /// last), or null.
  int? activeSlot(EbScene scene, Set<int> onLight) {
    bool matches(int s) => onLight.contains(s) && slots[s]?.scene == scene;
    if (lastLoaded != null && matches(lastLoaded!)) return lastLoaded;
    for (final int s in slots.keys.toList()..sort()) {
      if (matches(s)) return s;
    }
    return null;
  }
}

/// Presets of one light, saved in the `presetMeta` collection
/// ({fixtureId: {slot: entry}}).
final NotifierProviderFamily<PresetMetaNotifier, PresetMeta, String>
presetMetaProvider =
    NotifierProvider.family<PresetMetaNotifier, PresetMeta, String>(
      PresetMetaNotifier.new,
    );

final class PresetMetaNotifier extends Notifier<PresetMeta> {
  PresetMetaNotifier(this.fixtureId);
  final String fixtureId;

  static const String collection = 'presetMeta';

  JsonStore? get _store => ref.read(appSessionProvider)?.store;

  @override
  PresetMeta build() {
    final JsonStore? store = ref.watch(appSessionProvider)?.store;
    final Object? all = store?.read(collection);
    final Object? mine = all is Map<String, Object?> ? all[fixtureId] : null;
    if (mine is! Map<String, Object?>) return PresetMeta.empty;
    final Map<int, PresetEntry> slots = <int, PresetEntry>{};
    for (final MapEntry<String, Object?> e in mine.entries) {
      final int? slot = int.tryParse(e.key);
      final PresetEntry? entry = PresetEntry.fromJson(e.value);
      if (slot != null && entry != null) slots[slot] = entry;
    }
    return PresetMeta(slots);
  }

  void rename(int slot, String name) {
    final String n = name.trim();
    final PresetEntry old = state[slot] ?? const PresetEntry();
    _put(slot, PresetEntry(name: n.isEmpty ? null : n, scene: old.scene));
  }

  /// After a save: the name (if given) and what the light stored.
  void saved(int slot, EbScene? scene, {String? name}) {
    final PresetEntry old = state[slot] ?? const PresetEntry();
    _put(
      slot,
      PresetEntry(name: name ?? old.name, scene: scene ?? old.scene),
      lastLoaded: slot,
    );
  }

  /// After a load: the complete scene the light reported.
  void loaded(int slot, EbScene? scene) {
    final PresetEntry old = state[slot] ?? const PresetEntry();
    _put(
      slot,
      PresetEntry(name: old.name, scene: scene ?? old.scene),
      lastLoaded: slot,
    );
  }

  void clear(int slot) {
    final Map<int, PresetEntry> slots = Map<int, PresetEntry>.of(state.slots)
      ..remove(slot);
    state = PresetMeta(
      slots,
      lastLoaded: state.lastLoaded == slot ? null : state.lastLoaded,
    );
    _write();
  }

  /// After a factory reset: the light has no presets any more.
  void clearAll() {
    state = PresetMeta.empty;
    _write();
  }

  void _put(int slot, PresetEntry e, {int? lastLoaded}) {
    state = PresetMeta(<int, PresetEntry>{
      ...state.slots,
      slot: e,
    }, lastLoaded: lastLoaded ?? state.lastLoaded);
    _write();
  }

  void _write() {
    final JsonStore? store = _store;
    if (store == null) return;
    final Object? old = store.read(collection);
    final Map<String, Object?> all = old is Map<String, Object?>
        ? Map<String, Object?>.of(old)
        : <String, Object?>{};
    if (state.slots.isEmpty) {
      all.remove(fixtureId);
    } else {
      all[fixtureId] = <String, Object?>{
        for (final MapEntry<int, PresetEntry> e in state.slots.entries)
          '${e.key}': e.value.toJson(),
      };
    }
    store.write(collection, all);
  }
}
