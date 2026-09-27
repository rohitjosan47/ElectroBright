import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../core/color/colour_engine.dart';
import '../core/color/hsv.dart';
import '../core/model/channel_color.dart';
import '../core/model/channel_layout.dart';
import '../core/store/json_store.dart';
import 'group_capabilities.dart';

/// One light's look in a group preset.
@immutable
final class GroupPresetLight {
  const GroupPresetLight({
    required this.on,
    required this.colour,
    this.pick,
    required this.mode,
    required this.speed,
    required this.frequency,
  });

  final bool on;

  /// The light's own channels.
  final ChannelColor colour;

  /// What the user picked for [colour], when known (the light's own screen
  /// shows exactly it).
  final ColourIntent? pick;
  final int mode;
  final int speed;
  final int frequency;

  Map<String, Object?> toJson() => <String, Object?>{
    'on': on,
    'layout': colour.layout.wire,
    'colour': colour.toJson(),
    if (_pickJson(pick) case final Map<String, Object?> p) 'pick': p,
    'mode': mode,
    'speed': speed,
    'frequency': frequency,
  };

  static GroupPresetLight? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final ChannelLayout? layout = switch (json['layout']) {
      final String w => ChannelLayout.fromWire(w),
      _ => null,
    };
    final ChannelColor? colour = layout == null
        ? null
        : ChannelColor.fromJson(layout, json['colour']);
    final (Object? mode, Object? speed, Object? frequency) = (
      json['mode'],
      json['speed'],
      json['frequency'],
    );
    if (colour == null || mode is! int || speed is! int || frequency is! int) {
      return null;
    }
    return GroupPresetLight(
      on: json['on'] != false,
      colour: colour,
      pick: _pickFromJson(json['pick']),
      mode: mode,
      speed: speed,
      frequency: frequency,
    );
  }

  static Map<String, Object?>? _pickJson(ColourIntent? pick) => switch (pick) {
    HsvIntent(:final Hsv hsv, :final double white) => <String, Object?>{
      'hsv': <double>[hsv.h, hsv.s, hsv.v],
      'white': white,
    },
    WhiteIntent(:final double kelvin, :final double level) => <String, Object?>{
      'kelvin': kelvin,
      'level': level,
    },
    RawIntent() || null => null,
  };

  static ColourIntent? _pickFromJson(Object? json) => switch (json) {
    {'hsv': [final num h, final num s, final num v], 'white': final num w} =>
      HsvIntent(
        Hsv(h.toDouble(), s.toDouble(), v.toDouble()),
        white: w.toDouble(),
      ),
    {'kelvin': final num k, 'level': final num l} => WhiteIntent(
      k.toDouble(),
      l.toDouble(),
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is GroupPresetLight &&
      other.on == on &&
      other.colour == colour &&
      other.pick == pick &&
      other.mode == mode &&
      other.speed == speed &&
      other.frequency == frequency;
  @override
  int get hashCode => Object.hash(on, colour, pick, mode, speed, frequency);
}

/// A group preset, stored on the phone (never in the lights' own slots):
/// the group's master brightness and each light's look. The sleep timer is
/// never part of it.
@immutable
final class GroupPreset {
  GroupPreset({
    required this.name,
    required this.master,
    required Map<String, GroupPresetLight> lights,
  }) : lights = Map<String, GroupPresetLight>.unmodifiable(lights);

  final String name;

  /// The group's master brightness; each light gets it at its trim.
  final int master;

  /// By fixture id.
  final Map<String, GroupPresetLight> lights;

  GroupPreset renamed(String name) =>
      GroupPreset(name: name, master: master, lights: lights);

  /// Without the lights not in [ids]; null when none is left.
  GroupPreset? keeping(Set<String> ids) {
    if (lights.keys.every(ids.contains)) return this;
    final Map<String, GroupPresetLight> kept = <String, GroupPresetLight>{
      for (final MapEntry<String, GroupPresetLight> e in lights.entries)
        if (ids.contains(e.key)) e.key: e.value,
    };
    return kept.isEmpty
        ? null
        : GroupPreset(name: name, master: master, lights: kept);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'master': master,
    'lights': <String, Object?>{
      for (final String id in lights.keys.toList()..sort())
        id: lights[id]!.toJson(),
    },
  };

  static GroupPreset? fromJson(Object? json) {
    if (json case {
      'name': final String name,
      'master': final int master,
      'lights': final Map<String, Object?> raw,
    }) {
      final Map<String, GroupPresetLight> lights = <String, GroupPresetLight>{
        for (final MapEntry<String, Object?> e in raw.entries)
          if (GroupPresetLight.fromJson(e.value) case final GroupPresetLight l)
            e.key: l,
      };
      if (lights.isEmpty) return null;
      return GroupPreset(
        name: name,
        master: master.clamp(0, 255),
        lights: lights,
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupPreset &&
          other.name == name &&
          other.master == master &&
          const MapEquality<String, GroupPresetLight>().equals(
            other.lights,
            lights,
          );
  @override
  int get hashCode => Object.hash(
    name,
    master,
    const MapEquality<String, GroupPresetLight>().hash(lights),
  );
}

/// A group's preset slots in the store: [slots] entries, each a preset or
/// null.
abstract final class GroupPresets {
  static const int slots = 15;

  static String key(GroupKind kind) => 'group.presets.${kind.name}';

  static List<GroupPreset?> read(JsonStore store, GroupKind kind) {
    final Object? raw = store.read(key(kind));
    final List<Object?> list = raw is List<Object?> ? raw : const <Object?>[];
    return List<GroupPreset?>.unmodifiable(<GroupPreset?>[
      for (int i = 0; i < slots; i++)
        i < list.length ? GroupPreset.fromJson(list[i]) : null,
    ]);
  }

  static void write(JsonStore store, GroupKind kind, List<GroupPreset?> all) =>
      store.write(key(kind), <Object?>[
        for (final GroupPreset? p in all) p?.toJson(),
      ]);
}
