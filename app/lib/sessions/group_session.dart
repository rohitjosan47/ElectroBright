import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../core/color/colour_engine.dart';
import '../core/model/channel_color.dart';
import '../core/model/channel_layout.dart';
import '../core/model/fixture.dart';
import '../core/model/light_capabilities.dart';
import '../core/protocol/eb/eb_scene.dart';
import '../core/store/json_store.dart';
import '../core/util/scheduler.dart';
import '../drivers/electrobright/eb_types.dart';
import 'connection_manager.dart';
import 'fixture_registry.dart';
import 'fixture_session.dart';
import 'group_capabilities.dart';
import 'group_presets.dart';

/// One member of the group as the UI lists it.
@immutable
final class GroupMember {
  const GroupMember(
    this.id,
    this.phase, {
    this.limitedOut = false,
    this.following = false,
    this.own = false,
    this.trim = 1,
  });
  final String id;
  final LinkPhase phase;

  /// Not connected for the group: the connection budget ran out.
  final bool limitedOut;

  /// Got a group command since it last joined.
  final bool following;

  /// Detached by a change on its own controls: group commands skip it
  /// until it rejoins.
  final bool own;

  /// Its brightness trim in the group (0.05..1).
  final double trim;

  @override
  bool operator ==(Object other) =>
      other is GroupMember &&
      other.id == id &&
      other.phase == phase &&
      other.limitedOut == limitedOut &&
      other.following == following &&
      other.own == own &&
      other.trim == trim;
  @override
  int get hashCode => Object.hash(id, phase, limitedOut, following, own, trim);
  @override
  String toString() =>
      'GroupMember($id, ${phase.name}${limitedOut ? ', limited out' : ''}'
      '${following ? ', following' : ''}${own ? ', own' : ''})';
}

/// Where the group's lights are: each member plus the counts.
@immutable
final class GroupStatus {
  const GroupStatus(
    this.kind, {
    this.exists = false,
    this.active = false,
    this.members = const <GroupMember>[],
    this.excluded = const <String>[],
    this._capabilities,
    this.presets = const <GroupPreset?>[],
    this.activePreset,
  });

  final GroupKind kind;

  /// The group has 2 or more lights (left-out ones included).
  final bool exists;
  final bool active;

  /// The group's lights not left out, in Home's order (own ones included).
  final List<GroupMember> members;

  /// Lights left out of the group, in Home's order.
  final List<String> excluded;

  /// The group's controls, from the lights it drives.
  GroupCapabilities get capabilities =>
      _capabilities ?? GroupCapabilities.none(kind);
  final GroupCapabilities? _capabilities;

  /// The group's preset slots ([GroupPresets.slots]; null = empty).
  final List<GroupPreset?> presets;

  /// The slot last applied, until the next group command.
  final int? activePreset;

  int get total => members.length;
  int get ready => _count((GroupMember m) => m.phase == LinkPhase.ready);
  int get connecting => _count(
    (GroupMember m) =>
        m.phase == LinkPhase.waiting ||
        m.phase == LinkPhase.connecting ||
        m.phase == LinkPhase.handshaking,
  );
  int get unavailable => _count(
    (GroupMember m) =>
        m.phase == LinkPhase.unavailable ||
        m.phase == LinkPhase.incompatible ||
        m.phase == LinkPhase.bluetoothOff,
  );
  int get limitedOut => _count((GroupMember m) => m.limitedOut);

  int _count(bool Function(GroupMember) test) => members.where(test).length;

  @override
  bool operator ==(Object other) =>
      other is GroupStatus &&
      other.kind == kind &&
      other.exists == exists &&
      other.active == active &&
      const ListEquality<GroupMember>().equals(other.members, members) &&
      const ListEquality<String>().equals(other.excluded, excluded) &&
      other.capabilities == capabilities &&
      const ListEquality<GroupPreset?>().equals(other.presets, presets) &&
      other.activePreset == activePreset;
  @override
  int get hashCode => Object.hash(
    kind,
    exists,
    active,
    Object.hashAll(members),
    Object.hashAll(excluded),
    capabilities,
    Object.hashAll(presets),
    activePreset,
  );
}

/// A value the ready members share: none (no ready member, or none has
/// it), mixed, or the one value they all have.
@immutable
final class Common<T extends Object> {
  const Common.none() : value = null, mixed = false;
  const Common.mixed() : value = null, mixed = true;
  const Common.of(T this.value) : mixed = false;

  /// [values]: one per member.
  factory Common.from(Iterable<T?> values) {
    final List<T?> all = values.toList();
    if (all.isEmpty || all.every((T? v) => v == null)) {
      return Common<T>.none();
    }
    final T? first = all.first;
    if (first == null) return Common<T>.mixed();
    for (final T? v in all.skip(1)) {
      if (v != first) {
        return Common<T>.mixed();
      }
    }
    return Common<T>.of(first);
  }

  final T? value;
  final bool mixed;
  bool get isNone => value == null && !mixed;

  @override
  bool operator ==(Object other) =>
      other is Common<T> && other.value == value && other.mixed == mixed;
  @override
  int get hashCode => Object.hash(value, mixed);
  @override
  String toString() => mixed ? 'mixed' : (value == null ? 'none' : '$value');
}

/// What the ready members show together (each reader value-equal).
@immutable
final class GroupLook {
  const GroupLook({
    this.brightness = const Common<int>.none(),
    this.anyOn = false,
    this.mode = const Common<int>.none(),
    this.colour = const Common<ColourIntent>.none(),
    this.timerDeadline = const Common<Duration>.none(),
    this.kelvin,
    this.fireworkColorMode = const Common<int>.none(),
    this.clubColorMode = const Common<int>.none(),
    this.policeColorMode = const Common<int>.none(),
    this.policeA = const Common<Rgb>.none(),
    this.policeB = const Common<Rgb>.none(),
    this.master,
  });

  /// The lights' master brightness, as they show it; "Mixed" when they
  /// differ (then [master] is what the pill shows).
  final Common<int> brightness;

  /// The group's last master brightness (its reference look); null before
  /// the first group brightness or preset.
  final int? master;
  final bool anyOn;
  final Common<int> mode;
  final Common<ColourIntent> colour;

  /// Scheduler time the sleep timers fire (equal within 2 s).
  final Common<Duration> timerDeadline;

  /// White group: the CCT lights' common temperature, or their mean when
  /// they differ; null without a ready CCT light (and in the colour group).
  final double? kelvin;

  /// Colour group: the colour source of each kind, over the lights that
  /// have that effect.
  final Common<int> fireworkColorMode;
  final Common<int> clubColorMode;
  final Common<int> policeColorMode;

  /// Colour group: the police beacons' colours (R, G, B), over the lights
  /// that have Police.
  final Common<Rgb> policeA;
  final Common<Rgb> policeB;

  Common<int> colorMode(EbColorModeKind kind) => switch (kind) {
    EbColorModeKind.firework => fireworkColorMode,
    EbColorModeKind.club => clubColorMode,
    EbColorModeKind.police => policeColorMode,
  };

  Common<Rgb> police(EbPoliceSlot slot) =>
      slot == EbPoliceSlot.a ? policeA : policeB;

  @override
  bool operator ==(Object other) =>
      other is GroupLook &&
      other.brightness == brightness &&
      other.anyOn == anyOn &&
      other.mode == mode &&
      other.colour == colour &&
      other.timerDeadline == timerDeadline &&
      other.kelvin == kelvin &&
      other.fireworkColorMode == fireworkColorMode &&
      other.clubColorMode == clubColorMode &&
      other.policeColorMode == policeColorMode &&
      other.policeA == policeA &&
      other.policeB == policeB &&
      other.master == master;
  @override
  int get hashCode => Object.hash(
    master,
    brightness,
    anyOn,
    mode,
    colour,
    timerDeadline,
    kelvin,
    fireworkColorMode,
    clubColorMode,
    policeColorMode,
    policeA,
    policeB,
  );
}

/// A colour's red, green and blue channels.
typedef Rgb = (int, int, int);

/// How one command went across the group.
@immutable
final class GroupResult {
  const GroupResult({this.ok = 0, this.failed = 0, this.skipped = 0});

  /// Sent (and, where the light answers, confirmed).
  final int ok;
  final int failed;

  /// Not sent: the light cannot do it.
  final int skipped;

  @override
  bool operator ==(Object other) =>
      other is GroupResult &&
      other.ok == ok &&
      other.failed == failed &&
      other.skipped == skipped;
  @override
  int get hashCode => Object.hash(ok, failed, skipped);
  @override
  String toString() => 'GroupResult(ok $ok, failed $failed, skipped $skipped)';
}

/// How a preset save went: [saved] of the [total] lights the group drives
/// (the others were not ready or not following).
@immutable
final class GroupSaveResult {
  const GroupSaveResult(this.saved, this.total);
  final int saved;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is GroupSaveResult && other.saved == saved && other.total == total;
  @override
  int get hashCode => Object.hash(saved, total);
  @override
  String toString() => 'GroupSaveResult($saved of $total)';
}

/// The last look sent to the group: a colour, a mode with its settings, or
/// a preset (a look per light).
sealed class _Look {
  const _Look();
}

final class _ColourLook extends _Look {
  const _ColourLook(this.intent);

  /// A colour (colour group) or a white at full level (white group).
  final ColourIntent intent;
}

final class _ModeLook extends _Look {
  const _ModeLook(this.mode, {this.speed, this.frequency});
  final int mode;
  final int? speed;
  final int? frequency;
}

final class _PresetLook extends _Look {
  const _PresetLook(this.preset);
  final GroupPreset preset;
}

/// The group's reference look (persisted per group): what every light the
/// group drives shows, as far as group commands and presets set it. A light
/// that rejoins gets it, so it matches the group at once, also in a later
/// session.
final class _Reference {
  _Reference(this._store, this._key) {
    if (_store.read(_key) case final Map<String, Object?> j) _read(j);
  }

  final JsonStore _store;
  final String _key;

  /// Colour group: the colour; white group: the temperature (full level).
  ColourIntent? colour;
  int? mode;
  final Map<int, int> speeds = <int, int>{};
  final Map<int, int> frequencies = <int, int>{};
  final Map<EbColorModeKind, int> colorModes = <EbColorModeKind, int>{};
  final Map<EbPoliceSlot, HsvIntent> police = <EbPoliceSlot, HsvIntent>{};
  int? master;
  bool? power;

  /// The preset last applied (each light's own look); later commands apply
  /// on top of it.
  GroupPreset? preset;

  bool get isEmpty =>
      colour == null &&
      mode == null &&
      speeds.isEmpty &&
      frequencies.isEmpty &&
      colorModes.isEmpty &&
      police.isEmpty &&
      master == null &&
      power == null &&
      preset == null;

  /// A preset replaces the whole look.
  void applied(GroupPreset p) {
    colour = null;
    mode = null;
    speeds.clear();
    frequencies.clear();
    colorModes.clear();
    police.clear();
    power = null;
    master = p.master;
    preset = p;
  }

  /// Drops the lights not in [ids] from the preset it keeps.
  void prune(Set<String> ids) {
    final GroupPreset? p = preset;
    if (p == null) return;
    final GroupPreset? kept = p.keeping(ids);
    if (identical(kept, p)) return;
    preset = kept;
    save();
  }

  void save() => _store.write(_key, <String, Object?>{
    if (colour case WhiteIntent(:final double kelvin)) 'kelvin': kelvin,
    if (colour case final HsvIntent c) 'colour': GroupPresetLight.pickJson(c),
    if (mode case final int m) 'mode': m,
    if (speeds.isNotEmpty) 'speeds': _intMap(speeds),
    if (frequencies.isNotEmpty) 'frequencies': _intMap(frequencies),
    if (colorModes.isNotEmpty)
      'colorModes': <String, Object?>{
        for (final MapEntry<EbColorModeKind, int> e in colorModes.entries)
          e.key.name: e.value,
      },
    if (police.isNotEmpty)
      'police': <String, Object?>{
        for (final MapEntry<EbPoliceSlot, HsvIntent> e in police.entries)
          e.key.name: GroupPresetLight.pickJson(e.value),
      },
    if (master case final int m) 'master': m,
    if (power case final bool p) 'power': p,
    if (preset case final GroupPreset p) 'preset': p.toJson(),
  });

  static Map<String, Object?> _intMap(Map<int, int> m) => <String, Object?>{
    for (final int k in m.keys.toList()..sort()) '$k': m[k],
  };

  void _read(Map<String, Object?> j) {
    colour = switch (j) {
      {'kelvin': final num k} => WhiteIntent(k.toDouble(), 1),
      {'colour': final Object c} => switch (GroupPresetLight.pickFromJson(c)) {
        final HsvIntent i => i,
        _ => null,
      },
      _ => null,
    };
    if (j['mode'] case final int m) mode = m;
    void ints(Object? raw, Map<int, int> into) {
      if (raw is! Map<String, Object?>) return;
      for (final MapEntry<String, Object?> e in raw.entries) {
        if ((int.tryParse(e.key), e.value) case (final int k, final int v)) {
          into[k] = v;
        }
      }
    }

    ints(j['speeds'], speeds);
    ints(j['frequencies'], frequencies);
    if (j['colorModes'] case final Map<String, Object?> m) {
      for (final EbColorModeKind k in EbColorModeKind.values) {
        if (m[k.name] case final int v) colorModes[k] = v;
      }
    }
    if (j['police'] case final Map<String, Object?> m) {
      for (final EbPoliceSlot s in EbPoliceSlot.values) {
        if (GroupPresetLight.pickFromJson(m[s.name]) case final HsvIntent i) {
          police[s] = i;
        }
      }
    }
    if (j['master'] case final int m) master = m;
    if (j['power'] case final bool p) power = p;
    preset = GroupPreset.fromJson(j['preset']);
  }
}

/// The per-light group keys, shared by both groups: a light is in one group
/// only, so they stay unambiguous.
final class _GroupMemory {
  _GroupMemory(this._store) {
    excluded = _readIds(GroupSession.excludedKey);
    following = _readIds(GroupSession.followingKey);
    own = _readIds(GroupSession.ownKey);
    rejoining = _readIds(GroupSession.rejoiningKey);
    trim = <String, double>{
      if (_store.read(GroupSession.trimKey) case final Map<String, Object?> m)
        for (final MapEntry<String, Object?> e in m.entries)
          if (e.value case final num t)
            e.key: GroupSession._clampTrim(t.toDouble()),
    };
  }

  final JsonStore _store;
  late Set<String> excluded;
  late Set<String> following;
  late Set<String> own;

  /// Rejoined while not connected: they get the reference look when they
  /// connect with the group open.
  late Set<String> rejoining;
  late Map<String, double> trim;

  Set<String> _readIds(String key) => <String>{
    ...switch (_store.read(key)) {
      final List<Object?> l => l.whereType<String>(),
      _ => const <String>[],
    },
  };

  /// Forgets the lights not in [ids].
  void prune(Set<String> ids) {
    if (!<String>[
      ...excluded,
      ...following,
      ...own,
      ...rejoining,
      ...trim.keys,
    ].any((String id) => !ids.contains(id))) {
      return;
    }
    excluded = excluded.where(ids.contains).toSet();
    following = following.where(ids.contains).toSet();
    own = own.where(ids.contains).toSet();
    rejoining = rejoining.where(ids.contains).toSet();
    trim.removeWhere((String id, _) => !ids.contains(id));
    save();
  }

  void save() {
    _store.write(GroupSession.excludedKey, excluded.toList()..sort());
    _store.write(GroupSession.followingKey, following.toList()..sort());
    _store.write(GroupSession.ownKey, own.toList()..sort());
    _store.write(GroupSession.rejoiningKey, rejoining.toList()..sort());
    _store.write(GroupSession.trimKey, <String, Object?>{
      for (final String id in trim.keys.toList()..sort()) id: trim[id],
    });
  }
}

/// The two automatic groups, created and disposed together. Only one is
/// active at a time: activating one deactivates the other.
final class GroupSessions {
  GroupSessions({
    required FixtureRegistry registry,
    required ConnectionManager connections,
    required JsonStore store,
    required Scheduler scheduler,
  }) {
    final _GroupMemory memory = _GroupMemory(store);
    _all = <GroupKind, GroupSession>{
      for (final GroupKind kind in GroupKind.values)
        kind: GroupSession._(
          kind,
          registry: registry,
          connections: connections,
          store: store,
          scheduler: scheduler,
          memory: memory,
          onActivate: _activated,
        ),
    };
  }

  late final Map<GroupKind, GroupSession> _all;

  GroupSession of(GroupKind kind) => _all[kind]!;
  GroupSession get colour => of(GroupKind.colour);
  GroupSession get white => of(GroupKind.white);

  void _activated(GroupSession active) {
    for (final GroupSession g in _all.values) {
      if (!identical(g, active)) g.deactivate();
    }
  }

  void dispose() {
    for (final GroupSession g in _all.values) {
      g.dispose();
    }
  }
}

/// One automatic group: the saved lights of its [kind] (a group exists with
/// 2 or more), one control surface sending the same commands at the same
/// moment to every one not left out. It broadcasts; each light runs its own
/// effect clock.
final class GroupSession {
  GroupSession._(
    this.kind, {
    required this._registry,
    required this._connections,
    required this._store,
    required this._scheduler,
    required this._memory,
    required this._onActivate,
  }) {
    _presets = GroupPresets.read(_store, kind);
    _ref = _Reference(_store, lookKey(kind));
    _regSub = _registry.changes.listen((_) => _onFixtures());
    _onFixtures();
  }

  /// Fixture ids left out of their group (persisted).
  static const String excludedKey = 'group.excluded';

  /// Lights a group command (or catch-up) reached since they last joined
  /// (persisted). Only these are detached by a change on their own
  /// controls.
  static const String followingKey = 'group.following';

  /// Lights detached by a change on their own controls (persisted).
  static const String ownKey = 'group.own';

  /// Lights rejoined while not connected (persisted).
  static const String rejoiningKey = 'group.rejoining';

  /// The group's reference look (persisted): `group.look.colour` and
  /// `group.look.white`.
  static String lookKey(GroupKind kind) => 'group.look.${kind.name}';

  /// Per-light brightness trim, id -> 0.05..1 (persisted; 1 when absent).
  static const String trimKey = 'group.trim';

  static const double minTrim = 0.05;

  /// A group needs this many lights of its kind.
  static const int minLights = 2;

  /// A timer with less left than this is not sent to a late light.
  static const Duration minCatchUpTimer = Duration(seconds: 5);

  final GroupKind kind;
  final FixtureRegistry _registry;
  final ConnectionManager _connections;
  final JsonStore _store;
  final Scheduler _scheduler;
  final _GroupMemory _memory;
  final void Function(GroupSession) _onActivate;

  late final StreamSubscription<List<Fixture>> _regSub;
  final Map<String, StreamSubscription<FixtureStatus>> _subs =
      <String, StreamSubscription<FixtureStatus>>{};
  final Map<String, StreamSubscription<String>> _userSubs =
      <String, StreamSubscription<String>>{};
  final Set<String> _ready = <String>{};
  final Map<String, Want> _wants = <String, Want>{};
  Set<String> _limitedOut = const <String>{};
  bool _active = false;
  bool _disposed = false;
  late List<GroupPreset?> _presets;
  int? _activePreset;
  late final _Reference _ref;

  /// A level-in-group drag: the light and the master it trims.
  (String, int)? _trimDrag;

  // What the user sent in this activation (never persisted).
  _Look? _look;
  int? _brightness;
  bool? _power;
  final Map<EbColorModeKind, int> _colorModes = <EbColorModeKind, int>{};
  final Map<EbPoliceSlot, HsvIntent> _police = <EbPoliceSlot, HsvIntent>{};

  /// Set: a timer was sent; its deadline, or null when it was cancelled.
  (Duration?,)? _timer;

  late GroupStatus _status = GroupStatus(kind);
  GroupLook _groupLook = const GroupLook();
  final StreamController<GroupStatus> _statuses =
      StreamController<GroupStatus>.broadcast();
  final StreamController<GroupLook> _looks =
      StreamController<GroupLook>.broadcast();

  bool get active => _active;

  /// Whether the group has enough lights to exist.
  bool get exists => _lights.length >= minLights;

  /// Lights this phone connects at once (the group's budget).
  int get budget => _connections.policy.maxConnections;

  /// Whose timer span the sleep-timer sheet keeps for the group.
  String get timerSpanKey => 'group-${kind.name}';
  GroupStatus get status => _status;
  Stream<GroupStatus> get statuses => _statuses.stream;
  GroupLook get look => _groupLook;
  Stream<GroupLook> get looks => _looks.stream;

  /// Every saved light of the group's kind, in Home's order (a light
  /// without a fixture type yet is in no group).
  List<Fixture> get _lights => <Fixture>[
    for (final Fixture f in _registry.fixtures)
      if (GroupKind.holds(kind, f)) f,
  ];

  bool _isMine(String id) => switch (_registry.byId(id)) {
    final Fixture f => GroupKind.holds(kind, f),
    null => false,
  };

  /// Member ids (not left out) in Home's order.
  List<String> get members => <String>[
    for (final Fixture f in _lights)
      if (!_memory.excluded.contains(f.id)) f.id,
  ];

  bool isExcluded(String id) => _memory.excluded.contains(id);
  bool isFollowing(String id) => _memory.following.contains(id);
  bool isOwn(String id) => _memory.own.contains(id);

  /// The light's brightness trim (0.05..1).
  double trimOf(String id) => _memory.trim[id] ?? 1;

  /// Leaves a light out of the group, or takes it back in ([rejoin]).
  void setExcluded(String id, {required bool excluded}) {
    if (!_isMine(id)) return;
    if (!excluded) return rejoin(id);
    if (!_memory.excluded.add(id)) return;
    _memory.following.remove(id);
    _memory.save();
    if (_active) _allocate();
    _emit();
  }

  /// Takes a light back into the group (from its own settings or from being
  /// left out) and gives it the group's reference look: at once if it is
  /// connected, otherwise when it connects with the group open. It follows
  /// the group again once that look (or a group command) reaches it.
  void rejoin(String id) => _rejoin(<String>[id]);

  /// [rejoin] for every light of the group.
  void rejoinAll() => _rejoin(<String>[for (final Fixture f in _lights) f.id]);

  void _rejoin(List<String> ids) {
    final List<String> known = ids.where(_isMine).toList();
    if (known.isEmpty) return;
    for (final String id in known) {
      _memory.own.remove(id);
      _memory.excluded.remove(id);
      if (!_ref.isEmpty) _memory.rejoining.add(id);
    }
    _memory.save();
    if (_active) _allocate();
    for (final String id in known) {
      if (_ready.contains(id)) _applyReference(id);
    }
    _emit();
  }

  /// Starts a level-in-group drag on light [id] (that light alone).
  void beginTrim(String id) {
    final FixtureSession? s = _trimTarget(id);
    if (s == null) return;
    _trimDrag = (id, _trimMaster(id, s.status.state!));
    s.beginGesture(EbKeys.brightness);
  }

  /// Ends it: the final value comes with [setTrim].
  void endTrim(String id) {
    if (_trimDrag?.$1 != id) return;
    _trimDrag = null;
    _connections.session(id)?.endGesture(EbKeys.brightness);
  }

  /// Sets a light's brightness trim; it applies to that light at once (as a
  /// group change: it never detaches the light). [live]: a frame of a drag,
  /// sent to that light only and not saved; the release saves it.
  void setTrim(String id, double trim, {bool live = false}) {
    if (!_isMine(id)) return;
    final double t = _clampTrim(trim);
    final double old = trimOf(id);
    final bool dragged = _trimDrag?.$1 == id;
    if (!live && t != old) {
      if (t == 1) {
        _memory.trim.remove(id);
      } else {
        _memory.trim[id] = t;
      }
      _memory.save();
    }
    if (t != old || dragged) {
      final FixtureSession? s = _trimTarget(id);
      if (s != null) {
        final int master = dragged
            ? _trimDrag!.$2
            : _trimMaster(id, s.status.state!, trim: old);
        s.setBrightness(
          trimmed(master, t),
          live: live,
          origin: CommandOrigin.group,
        );
      }
    }
    if (!live) _emit();
  }

  /// The light a trim moves: ready, driven by the group and on.
  FixtureSession? _trimTarget(String id) {
    final FixtureSession? s = _connections.session(id);
    final EbDeviceState? st = s?.status.state;
    if (s == null ||
        st == null ||
        st.sleeping ||
        !_ready.contains(id) ||
        !_drives(id)) {
      return null;
    }
    return s;
  }

  /// The master a light's trim applies to: the last one sent, else the
  /// group's reference, else its brightness at its [trim].
  int _trimMaster(String id, EbDeviceState st, {double? trim}) =>
      _masterFor(id) ??
      _ref.master ??
      math.min(255, (st.scene.brightness / (trim ?? trimOf(id))).round());

  static double _clampTrim(double t) => t.clamp(minTrim, 1.0);

  /// A light's brightness for the group's [master] at [trim]: never 0 while
  /// the master is above 0; 0 turns it off (its own off-at-zero path).
  static int trimmed(int master, double trim) =>
      master <= 0 ? 0 : math.max(1, (master * trim).round()).clamp(1, 255);

  /// The master every light's (brightness, trim) comes from, if there is
  /// one: trimmed lights read as the same setting, not as mixed.
  static Common<int> commonMaster(List<(int, double)> lights) {
    if (lights.isEmpty) return const Common<int>.none();
    // Candidates from the finest-stepped light (the largest trim).
    final (int b0, double t0) = lights.reduce(
      ((int, double) a, (int, double) b) => a.$2 >= b.$2 ? a : b,
    );
    bool fits(int m) =>
        lights.every(((int, double) l) => trimmed(m, l.$2) == l.$1);
    if (b0 == 0) {
      return fits(0) ? const Common<int>.of(0) : const Common<int>.mixed();
    }
    final int lo = b0 == 1 ? 1 : ((b0 - 0.5) / t0).ceil().clamp(1, 255);
    final int hi = ((b0 + 0.5) / t0).floor().clamp(1, 255);
    final double best = b0 / t0;
    final List<int> candidates = <int>[for (int m = lo; m <= hi; m++) m]
      ..sort((int a, int b) => (a - best).abs().compareTo((b - best).abs()));
    for (final int m in candidates) {
      if (fits(m)) return Common<int>.of(m);
    }
    return const Common<int>.mixed();
  }

  /// Connects the members (favourites first, then Home's order) up to the
  /// connection budget; the rest are reported as limited out. The other
  /// group is deactivated. Does nothing while the group doesn't exist.
  void activate() {
    if (_active || _disposed || !exists) return;
    _onActivate(this);
    _active = true;
    _allocate();
    _emit();
  }

  /// Releases every connection the group asked for and forgets what it sent.
  void deactivate() {
    if (!_active) return;
    _active = false;
    _releaseAll();
    _limitedOut = const <String>{};
    _look = null;
    _brightness = null;
    _power = null;
    _colorModes.clear();
    _police.clear();
    _timer = null;
    _activePreset = null;
    _emit();
  }

  /// Releases everything at once (nothing to wait for).
  void dispose() {
    deactivate();
    _disposed = true;
    unawaited(_regSub.cancel());
    for (final StreamSubscription<FixtureStatus> s in _subs.values) {
      unawaited(s.cancel());
    }
    for (final StreamSubscription<String> s in _userSubs.values) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _userSubs.clear();
    unawaited(_statuses.close());
    unawaited(_looks.close());
  }

  // ---- commands --------------------------------------------------------------------

  Future<GroupResult> setPower({required bool on}) {
    _command();
    _power = on;
    _remember(() => _ref.power = on);
    // Turning off cancels the sleep timers.
    if (!on) _timer = null;
    return _send(
      (FixtureSession s, _) => s.setPower(on: on, origin: CommandOrigin.group),
    );
  }

  /// [v] is the master: each light gets it at its trim. Each keeps its own
  /// off-at-zero handling (a release at 0 turns it off).
  Future<GroupResult> setBrightness(int v, {bool live = false}) {
    _command();
    _brightness = v;
    _remember(() => _ref.master = v, save: !live);
    return _send((FixtureSession s, _) {
      s.setBrightness(
        trimmed(v, trimOf(s.fixture.id)),
        live: live,
        origin: CommandOrigin.group,
      );
      return Future<EbResult>.value(EbResult.ok);
    });
  }

  void beginGesture(String key) {
    for (final FixtureSession s in _readySessions) {
      s.beginGesture(key);
    }
  }

  void endGesture(String key) {
    for (final FixtureSession s in _readySessions) {
      s.endGesture(key);
    }
  }

  /// The colour group's colour, on every light with its white LEDs off
  /// (RGBW's W and RGBCCT's CW/WW at 0), so all of them match. The white
  /// group has no colour: nothing is sent.
  Future<GroupResult> setColour(HsvIntent pick, {bool live = false}) =>
      _sendLook(GroupCapabilities.colourPick(pick), live: live);

  /// The white group's colour temperature at full level, on its CCT lights
  /// only, each clamped to its own range; W lights are skipped. The colour
  /// group has no temperature: nothing is sent.
  Future<GroupResult> setTemperature(double kelvin, {bool live = false}) =>
      _sendLook(WhiteIntent(kelvin, 1.0), live: live);

  Future<GroupResult> _sendLook(ColourIntent intent, {required bool live}) {
    if (!_takesColour(intent)) {
      return Future<GroupResult>.value(const GroupResult());
    }
    _command();
    _look = _ColourLook(intent);
    _remember(() => _ref.colour = intent, save: !live);
    return _send(
      (FixtureSession s, _) {
        _sendColour(s, _colourFor(s.fixture, intent)!, live: live);
        return Future<EbResult>.value(EbResult.ok);
      },
      supported: (FixtureSession s, _) => _colourFor(s.fixture, intent) != null,
    );
  }

  bool _takesColour(ColourIntent intent) => switch (intent) {
    HsvIntent() => kind == GroupKind.colour,
    WhiteIntent() => kind == GroupKind.white,
    RawIntent() => false,
  };

  Future<GroupResult> setMode(int mode) {
    _command();
    _look = _ModeLook(mode);
    _remember(() => _ref.mode = mode);
    return _send(
      (FixtureSession s, _) => s.setMode(mode, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(mode),
    );
  }

  Future<GroupResult> setSpeed(int mode, int v) {
    _command();
    final _Look? l = _look;
    if (l is _ModeLook && l.mode == mode) {
      _look = _ModeLook(mode, speed: v, frequency: l.frequency);
    }
    _remember(() => _ref.speeds[mode] = v);
    return _send(
      (FixtureSession s, _) => s.setSpeed(mode, v, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(mode),
    );
  }

  Future<GroupResult> setFrequency(int mode, int v) {
    _command();
    final _Look? l = _look;
    if (l is _ModeLook && l.mode == mode) {
      _look = _ModeLook(mode, speed: l.speed, frequency: v);
    }
    _remember(() => _ref.frequencies[mode] = v);
    return _send(
      (FixtureSession s, _) =>
          s.setFrequency(mode, v, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(mode),
    );
  }

  /// The colour group's colour source for the effects of [k] (0 = picked
  /// colours, 1 = automatic), on the lights that have that effect. The white
  /// group has none: nothing is sent.
  Future<GroupResult> setColorMode(EbColorModeKind k, int v) {
    if (kind != GroupKind.colour) {
      return Future<GroupResult>.value(const GroupResult());
    }
    _command();
    _colorModes[k] = v;
    _remember(() => _ref.colorModes[k] = v);
    return _send(
      (FixtureSession s, _) =>
          s.setColorMode(k, v, origin: CommandOrigin.group),
      supported: (_, LightCapabilities c) => c.supportsMode(k.mode),
    );
  }

  /// The colour group's police beacon [slot], with every white LED off,
  /// encoded for each light that has Police. The white group has none.
  Future<GroupResult> setPoliceColor(EbPoliceSlot slot, HsvIntent pick) {
    if (kind != GroupKind.colour) {
      return Future<GroupResult>.value(const GroupResult());
    }
    _command();
    final HsvIntent i = GroupCapabilities.colourPick(pick);
    _police[slot] = i;
    _remember(() => _ref.police[slot] = i);
    return _send(
      (FixtureSession s, _) => s.setPoliceColor(
        slot,
        _encode(s.fixture, i),
        origin: CommandOrigin.group,
      ),
      supported: (_, LightCapabilities c) =>
          c.supportsMode(EbColorModeKind.police.mode),
    );
  }

  static ChannelColor _encode(Fixture f, ColourIntent i) =>
      ColourEngine(f.whitePoints).encode(i, f.layout);

  /// Sleep timer on every ready light; 0 cancels. Never part of a preset.
  Future<GroupResult> setTimer(int seconds) {
    _timer = (
      seconds > 0 ? _scheduler.now + Duration(seconds: seconds) : null,
    );
    return _send(
      (FixtureSession s, _) => s.setTimer(seconds),
      supported: (_, LightCapabilities c) => c.hasTimer,
    );
  }

  /// Updates the reference look; [save]: also persist it (a drag saves on
  /// release).
  void _remember(void Function() change, {bool save = true}) {
    change();
    if (save) _ref.save();
  }

  /// A look command: the applied preset is no longer the group's look.
  void _command() {
    if (_activePreset == null) return;
    _activePreset = null;
    _emit();
  }

  // ---- presets -----------------------------------------------------------------------

  /// The group's preset slots ([GroupPresets.slots]; null = empty).
  List<GroupPreset?> get presets => _presets;

  /// The slot last applied, until the next group command.
  int? get activePreset => _activePreset;

  /// Saves (or overwrites) [slot] with the look of every ready light that
  /// follows the group, and the group's master. Lights not ready are left
  /// out; with none to save the slot is unchanged.
  GroupSaveResult savePreset(int slot, String name) {
    _checkSlot(slot);
    final List<String> driven = members.where(_drives).toList();
    final List<(String, EbDeviceState, GroupPresetLight)> saved =
        <(String, EbDeviceState, GroupPresetLight)>[
          for (final String id in driven)
            if (_ready.contains(id) && _memory.following.contains(id))
              if (_connections.session(id) case final FixtureSession s)
                if (s.status.state case final EbDeviceState st)
                  (
                    id,
                    st,
                    _presetLightOf(
                      s.status,
                      st,
                      effectColours: kind == GroupKind.colour,
                    ),
                  ),
        ];
    if (saved.isEmpty) return GroupSaveResult(0, driven.length);
    final List<(int, double)> levels = <(int, double)>[
      for (final (String id, EbDeviceState st, _) in saved)
        (st.scene.brightness, trimOf(id)),
    ];
    final int master =
        commonMaster(levels).value ??
        _brightness ??
        levels
            .map(((int, double) l) => (l.$1 / l.$2).round())
            .max
            .clamp(0, 255);
    _setPreset(
      slot,
      GroupPreset(
        name: name,
        master: master,
        lights: <String, GroupPresetLight>{
          for (final (String id, _, GroupPresetLight l) in saved) id: l,
        },
      ),
    );
    return GroupSaveResult(saved.length, driven.length);
  }

  void renamePreset(int slot, String name) {
    _checkSlot(slot);
    final GroupPreset? p = _presets[slot];
    if (p == null || p.name == name) return;
    _setPreset(slot, p.renamed(name));
  }

  void deletePreset(int slot) {
    _checkSlot(slot);
    if (_presets[slot] == null) return;
    if (_activePreset == slot) _activePreset = null;
    _setPreset(slot, null);
  }

  /// A group command: each ready light the group drives that is in the
  /// preset gets its colour, then its mode with speed and frequency, then
  /// the master at its current trim, then its power. Lights not in it are
  /// untouched; lights not ready get it when they connect.
  Future<GroupResult> applyPreset(int slot) {
    _checkSlot(slot);
    final GroupPreset? p = _presets[slot];
    if (p == null) return Future<GroupResult>.value(const GroupResult());
    _look = _PresetLook(p);
    _brightness = null;
    _power = null;
    _colorModes.clear();
    _police.clear();
    _activePreset = slot;
    _remember(() => _ref.applied(p));
    _emit();
    return _send((FixtureSession s, LightCapabilities c) {
      final String id = s.fixture.id;
      return _sendPresetLight(
        s,
        c,
        p.lights[id]!,
        brightness: trimmed(p.master, trimOf(id)),
        on: p.lights[id]!.on,
        origin: CommandOrigin.group,
      );
    }, supported: (FixtureSession s, _) => p.lights.containsKey(s.fixture.id));
  }

  void _checkSlot(int slot) =>
      RangeError.checkValueInInterval(slot, 0, GroupPresets.slots - 1, 'slot');

  void _setPreset(int slot, GroupPreset? p) {
    _presets = List<GroupPreset?>.unmodifiable(
      List<GroupPreset?>.of(_presets)..[slot] = p,
    );
    GroupPresets.write(_store, kind, _presets);
    _emit();
  }

  /// What a light shows, as a preset keeps it.
  /// With [effectColours] (colour group) the colour sources and police
  /// beacons are kept too.
  static GroupPresetLight _presetLightOf(
    FixtureStatus st,
    EbDeviceState s, {
    required bool effectColours,
  }) => GroupPresetLight(
    on: !s.sleeping && s.scene.brightness > 0,
    colour: s.scene.color,
    pick: switch (_pickOf(st)) {
      final ColourIntent i when i is! RawIntent => i,
      _ => null,
    },
    mode: s.scene.mode,
    speed: s.scene.speed,
    frequency: s.scene.frequency,
    colorModes: effectColours
        ? List<int>.unmodifiable(<int>[
            for (final EbColorModeKind k in EbColorModeKind.values)
              s.scene.colorMode(k),
          ])
        : null,
    policeA: effectColours ? s.scene.policeA : null,
    policeB: effectColours ? s.scene.policeB : null,
  );

  /// A preset light's look, in order: colour, mode with its settings, the
  /// colour sources and police beacons it keeps, brightness, power. A single
  /// white takes no colour; one the layout or firmware can't take is
  /// skipped.
  Future<EbResult> _sendPresetLight(
    FixtureSession s,
    LightCapabilities caps,
    GroupPresetLight l, {
    required int? brightness,
    required bool? on,
    required CommandOrigin origin,
  }) async {
    final Fixture f = s.fixture;
    final List<Future<EbResult>> sent = <Future<EbResult>>[];
    if (l.colour.layout == f.layout && f.layout != ChannelLayout.w) {
      s.setColor(l.colour, intent: l.pick, origin: origin);
    }
    if (caps.supportsMode(l.mode)) {
      sent
        ..add(s.setMode(l.mode, origin: origin))
        ..add(s.setSpeed(l.mode, l.speed, origin: origin))
        ..add(s.setFrequency(l.mode, l.frequency, origin: origin));
    }
    for (final EbColorModeKind k in EbColorModeKind.values) {
      final int? v = l.colorMode(k);
      if (v != null && caps.supportsMode(k.mode)) {
        sent.add(s.setColorMode(k, v, origin: origin));
      }
    }
    if (caps.supportsMode(EbColorModeKind.police.mode)) {
      for (final EbPoliceSlot slot in EbPoliceSlot.values) {
        final ChannelColor? c = l.police(slot);
        if (c != null && c.layout == f.layout) {
          sent.add(s.setPoliceColor(slot, c, origin: origin));
        }
      }
    }
    if (brightness != null) s.setBrightness(brightness, origin: origin);
    if (on != null) sent.add(s.setPower(on: on, origin: origin));
    final List<EbResult> results = await Future.wait(sent);
    return results.firstWhere(
      (EbResult r) => !r.isSuccess,
      orElse: () => EbResult.ok,
    );
  }

  // ---- sending -----------------------------------------------------------------------

  /// The group drives this light: in the group and not on its own settings.
  bool _drives(String id) =>
      !_memory.excluded.contains(id) && !_memory.own.contains(id);

  /// The master a light gets now: the last one sent, else the applied
  /// preset's (for its lights only).
  int? _masterFor(String id) =>
      _brightness ??
      switch (_look) {
        _PresetLook(:final GroupPreset preset)
            when preset.lights.containsKey(id) =>
          preset.master,
        _ => null,
      };

  Iterable<FixtureSession> get _readySessions sync* {
    for (final String id in members) {
      if (!_ready.contains(id) || _memory.own.contains(id)) continue;
      final FixtureSession? s = _connections.session(id);
      if (s != null) yield s;
    }
  }

  static LightCapabilities _capabilities(FixtureSession s) =>
      s.status.view?.firmware?.capabilities ?? s.fixture.capabilities;

  /// Sends to every ready light the group drives that can take it; one
  /// result for all. Each light it reaches follows the group.
  Future<GroupResult> _send(
    Future<EbResult> Function(FixtureSession s, LightCapabilities c) action, {
    bool Function(FixtureSession s, LightCapabilities c)? supported,
  }) async {
    int skipped = 0;
    bool followed = false;
    final List<Future<EbResult>> sent = <Future<EbResult>>[];
    for (final FixtureSession s in _readySessions.toList()) {
      final LightCapabilities c = _capabilities(s);
      if (supported != null && !supported(s, c)) {
        skipped++;
        continue;
      }
      sent.add(action(s, c));
      followed |= _memory.following.add(s.fixture.id);
    }
    if (followed) {
      _memory.save();
      _emit();
    }
    final List<EbResult> results = await Future.wait(sent);
    final int ok = results.where((EbResult r) => r.isSuccess).length;
    return GroupResult(ok: ok, failed: results.length - ok, skipped: skipped);
  }

  static GroupLight _groupLight(Fixture f) =>
      GroupLight(f.id, f.layout, f.whitePoints, f.capabilities);

  /// The group's [intent] as light [f] takes it, or null when it has no
  /// such LEDs: colours go to colour lights, temperatures to CCT lights.
  static ColourIntent? _colourFor(Fixture f, ColourIntent intent) =>
      switch (intent) {
        HsvIntent() => f.layout.hasColour ? intent : null,
        WhiteIntent(:final double kelvin) => GroupCapabilities.temperatureFor(
          kelvin,
          _groupLight(f),
        ),
        RawIntent() => null,
      };

  /// As the colour editor sends it: the encoding for this light, with the
  /// intent as the pick (so the light's own screen shows exactly it).
  static void _sendColour(
    FixtureSession s,
    ColourIntent intent, {
    required bool live,
    CommandOrigin origin = CommandOrigin.group,
  }) {
    final Fixture f = s.fixture;
    final ChannelColor c = ColourEngine(f.whitePoints).encode(intent, f.layout);
    s.setColor(c, live: live, intent: intent, origin: origin);
  }

  // ---- membership and connections ----------------------------------------------------

  void _onFixtures() {
    if (_disposed) return;
    final Set<String> all = <String>{
      for (final Fixture f in _registry.fixtures) f.id,
    };
    final Set<String> ids = <String>{for (final Fixture f in _lights) f.id};
    // Forgotten lights (or ones now of the other kind): out of the group's
    // list, their connection released.
    for (final String id in _subs.keys.toList()) {
      if (ids.contains(id)) continue;
      unawaited(_subs.remove(id)!.cancel());
      unawaited(_userSubs.remove(id)?.cancel());
      _ready.remove(id);
      _wants.remove(id)?.release();
    }
    // Every group key and preset forgets lights that are gone.
    _memory.prune(all);
    _ref.prune(all);
    final List<GroupPreset?> kept = <GroupPreset?>[
      for (final GroupPreset? p in _presets) p?.keeping(all),
    ];
    if (!const ListEquality<GroupPreset?>().equals(kept, _presets)) {
      _presets = List<GroupPreset?>.unmodifiable(kept);
      GroupPresets.write(_store, kind, _presets);
    }
    for (final String id in ids) {
      if (_subs.containsKey(id)) continue;
      final FixtureSession? s = _connections.session(id);
      if (s == null) continue;
      if (s.status.isReady) _ready.add(id);
      _subs[id] = s.statuses.listen((FixtureStatus st) => _onStatus(id, st));
      _userSubs[id] = s.userLookChanges.listen((_) => _onUserLook(id));
    }
    if (_active && !exists) return deactivate();
    if (_active) _allocate();
    _emit();
  }

  void _onStatus(String id, FixtureStatus st) {
    final bool ready = st.isReady;
    final bool became = ready && _ready.add(id);
    if (!ready) _ready.remove(id);
    if (became && _active && _drives(id)) {
      _memory.rejoining.contains(id) ? _applyReference(id) : _catchUp(id);
    }
    _emit();
  }

  /// The user changed a following light's look on its own controls: it
  /// keeps its own settings until it rejoins (also with the group closed).
  void _onUserLook(String id) {
    if (!_memory.following.remove(id)) return;
    _memory.own.add(id);
    _memory.save();
    _emit();
  }

  /// Wants for the first members up to the budget, favourites first.
  void _allocate() {
    final List<Fixture> ordered = <Fixture>[
      for (final Fixture f in _lights)
        if (!_memory.excluded.contains(f.id)) f,
    ];
    mergeSort(
      ordered,
      compare: (Fixture a, Fixture b) =>
          a.favourite == b.favourite ? 0 : (a.favourite ? -1 : 1),
    );
    final int budget = _connections.policy.maxConnections;
    final Set<String> keep = ordered
        .take(budget)
        .map((Fixture f) => f.id)
        .toSet();
    for (final String id in _wants.keys.toList()) {
      if (!keep.contains(id)) _wants.remove(id)!.release();
    }
    for (final String id in keep) {
      _wants.putIfAbsent(id, () => _connections.want(id, WantReason.group));
    }
    _limitedOut = ordered.skip(budget).map((Fixture f) => f.id).toSet();
  }

  void _releaseAll() {
    for (final Want w in _wants.values) {
      w.release();
    }
    _wants.clear();
  }

  /// A light the group drives that became ready (or rejoined) gets what the
  /// group was sent, as far as it applies to it: look (its own from an
  /// applied preset), brightness (at its trim), power, then the timer's
  /// remaining time. It follows the group.
  void _catchUp(String id) {
    final FixtureSession? s = _connections.session(id);
    if (s == null) return;
    final LightCapabilities caps = _capabilities(s);
    const CommandOrigin origin = CommandOrigin.system;
    bool sent = false;
    final int? b = _masterFor(id);
    final bool inPreset = switch (_look) {
      _PresetLook(:final GroupPreset preset) => preset.lights.containsKey(id),
      _ => false,
    };
    switch (_look) {
      case _PresetLook(:final GroupPreset preset)
          when preset.lights.containsKey(id):
        final GroupPresetLight l = preset.lights[id]!;
        unawaited(
          _sendPresetLight(
            s,
            caps,
            l,
            brightness: b == null ? null : trimmed(b, trimOf(id)),
            on: _power ?? l.on,
            origin: origin,
          ),
        );
        sent = true;
      case _ColourLook(:final ColourIntent intent)
          when _colourFor(s.fixture, intent) != null:
        _sendColour(
          s,
          _colourFor(s.fixture, intent)!,
          live: false,
          origin: origin,
        );
        sent = true;
      case _ModeLook(:final int mode, :final int? speed, :final int? frequency)
          when caps.supportsMode(mode):
        unawaited(s.setMode(mode, origin: origin));
        if (speed != null) unawaited(s.setSpeed(mode, speed, origin: origin));
        if (frequency != null) {
          unawaited(s.setFrequency(mode, frequency, origin: origin));
        }
        sent = true;
      case _PresetLook() || _ColourLook() || _ModeLook() || null:
        break;
    }
    // A preset light got its brightness and power with its look.
    if (!inPreset) {
      if (b != null) {
        s.setBrightness(trimmed(b, trimOf(id)), origin: origin);
        sent = true;
      }
      final bool? on = _power;
      if (on != null) {
        unawaited(s.setPower(on: on, origin: origin));
        sent = true;
      }
    }
    // The colour sources and beacons sent in this activation.
    for (final MapEntry<EbColorModeKind, int> e in _colorModes.entries) {
      if (!caps.supportsMode(e.key.mode)) continue;
      unawaited(s.setColorMode(e.key, e.value, origin: origin));
      sent = true;
    }
    if (caps.supportsMode(EbColorModeKind.police.mode)) {
      for (final MapEntry<EbPoliceSlot, HsvIntent> e in _police.entries) {
        unawaited(
          s.setPoliceColor(e.key, _encode(s.fixture, e.value), origin: origin),
        );
        sent = true;
      }
    }
    sent |= _catchUpTimer(s, caps);
    if (sent && _memory.following.add(id)) _memory.save();
  }

  /// The sleep timer sent in this activation, as the time it has left.
  bool _catchUpTimer(FixtureSession s, LightCapabilities caps) {
    final (Duration?,)? timer = _timer;
    if (timer == null || !caps.hasTimer) return false;
    final Duration? deadline = timer.$1;
    if (deadline == null) {
      if (s.status.state?.timerDeadline != null) unawaited(s.setTimer(0));
    } else {
      final Duration left = deadline - _scheduler.now;
      if (left >= minCatchUpTimer) unawaited(s.setTimer(left.inSeconds));
    }
    return true;
  }

  /// A rejoined light that is ready gets the group's reference look, as far
  /// as it applies to it: its own look from the applied preset, then the
  /// colour (or temperature), mode with speeds and frequencies, colour
  /// sources and beacons set since, then the master at its trim, then
  /// power (and the activation's timer). It follows the group once that
  /// reached it; with no reference look nothing is sent.
  void _applyReference(String id) {
    final FixtureSession? s = _connections.session(id);
    _memory.rejoining.remove(id);
    if (s == null || !_drives(id)) return _memory.save();
    final Fixture f = s.fixture;
    final LightCapabilities caps = _capabilities(s);
    const CommandOrigin origin = CommandOrigin.system;
    bool sent = false;
    final GroupPresetLight? inPreset = _ref.preset?.lights[id];
    if (inPreset != null) {
      unawaited(
        _sendPresetLight(
          s,
          caps,
          inPreset,
          brightness: null,
          on: null,
          origin: origin,
        ),
      );
      sent = true;
    }
    if (_ref.colour case final ColourIntent c) {
      if (_colourFor(f, c) case final ColourIntent mine) {
        _sendColour(s, mine, live: false, origin: origin);
        sent = true;
      }
    }
    if (_ref.mode case final int m when caps.supportsMode(m)) {
      unawaited(s.setMode(m, origin: origin));
      sent = true;
    }
    for (final MapEntry<int, int> e in _ref.speeds.entries) {
      if (!caps.supportsMode(e.key)) continue;
      unawaited(s.setSpeed(e.key, e.value, origin: origin));
      sent = true;
    }
    for (final MapEntry<int, int> e in _ref.frequencies.entries) {
      if (!caps.supportsMode(e.key)) continue;
      unawaited(s.setFrequency(e.key, e.value, origin: origin));
      sent = true;
    }
    for (final MapEntry<EbColorModeKind, int> e in _ref.colorModes.entries) {
      if (!caps.supportsMode(e.key.mode)) continue;
      unawaited(s.setColorMode(e.key, e.value, origin: origin));
      sent = true;
    }
    if (caps.supportsMode(EbColorModeKind.police.mode)) {
      for (final MapEntry<EbPoliceSlot, HsvIntent> e in _ref.police.entries) {
        unawaited(s.setPoliceColor(e.key, _encode(f, e.value), origin: origin));
        sent = true;
      }
    }
    if (_ref.master case final int m) {
      s.setBrightness(trimmed(m, trimOf(id)), origin: origin);
      sent = true;
    }
    if (_ref.power ?? inPreset?.on case final bool on) {
      unawaited(s.setPower(on: on, origin: origin));
      sent = true;
    }
    if (_active) sent |= _catchUpTimer(s, caps);
    if (sent) _memory.following.add(id);
    _memory.save();
  }

  // ---- what the UI shows -------------------------------------------------------------

  void _emit() {
    if (_disposed) return;
    final List<Fixture> lights = _lights;
    final List<String> ids = members;
    final List<String> driven = ids.where(_drives).toList();
    final GroupStatus status = GroupStatus(
      kind,
      exists: lights.length >= minLights,
      active: _active,
      members: <GroupMember>[
        for (final String id in ids)
          GroupMember(
            id,
            _connections.session(id)?.status.phase ?? LinkPhase.idle,
            limitedOut: _limitedOut.contains(id),
            following: _memory.following.contains(id),
            own: _memory.own.contains(id),
            trim: trimOf(id),
          ),
      ],
      excluded: <String>[
        for (final Fixture f in lights)
          if (_memory.excluded.contains(f.id)) f.id,
      ],
      capabilities: GroupCapabilities(kind, <GroupLight>[
        for (final String id in driven)
          if (_registry.byId(id) case final Fixture f) _groupLight(f),
      ]),
      presets: _presets,
      activePreset: _activePreset,
    );
    if (status != _status) {
      _status = status;
      _statuses.add(status);
    }
    final GroupLook look = _lookOf(driven);
    if (look != _groupLook) {
      _groupLook = look;
      _looks.add(look);
    }
  }

  GroupLook _lookOf(List<String> ids) {
    final List<FixtureStatus> ready = <FixtureStatus>[];
    final List<Fixture> fixtures = <Fixture>[];
    final List<LightCapabilities> caps = <LightCapabilities>[];
    for (final String id in ids) {
      final FixtureSession? s = _connections.session(id);
      if (s == null || !_ready.contains(id) || s.status.state == null) continue;
      ready.add(s.status);
      fixtures.add(s.fixture);
      caps.add(_capabilities(s));
    }
    final List<EbDeviceState> states = <EbDeviceState>[
      for (final FixtureStatus st in ready) st.state!,
    ];
    // The colour group's colour; the white group's temperature from its CCT
    // lights (a single white keeps its own white and never counts).
    bool shows(Fixture f) => kind == GroupKind.colour
        ? f.layout.hasColour
        : f.layout == ChannelLayout.cct;
    final List<ColourIntent> shown = <ColourIntent>[
      for (int i = 0; i < ready.length; i++)
        if (shows(fixtures[i])) _shownIntent(ready[i], fixtures[i]),
    ];
    final List<double> kelvins = <double>[
      if (kind == GroupKind.white)
        for (final ColourIntent i in shown)
          if (i case WhiteIntent(:final double kelvin)) kelvin,
    ];
    // Colour group: effect colours over the lights that have the effect.
    final bool colour = kind == GroupKind.colour;
    Iterable<EbScene> having(int mode) sync* {
      for (int i = 0; i < states.length; i++) {
        if (caps[i].supportsMode(mode)) yield states[i].scene;
      }
    }

    Common<int> colorMode(EbColorModeKind k) => colour
        ? Common<int>.from(having(k.mode).map((EbScene s) => s.colorMode(k)))
        : const Common<int>.none();
    Common<Rgb> police(EbPoliceSlot slot) => colour
        ? Common<Rgb>.from(
            having(EbColorModeKind.police.mode).map((EbScene s) {
              final ChannelColor c = s.police(slot);
              return (c[0], c[1], c[2]);
            }),
          )
        : const Common<Rgb>.none();
    return GroupLook(
      brightness: commonMaster(<(int, double)>[
        for (int i = 0; i < states.length; i++)
          (states[i].scene.brightness, trimOf(fixtures[i].id)),
      ]),
      anyOn: states.any(
        (EbDeviceState s) => !s.sleeping && s.scene.brightness > 0,
      ),
      mode: Common<int>.from(states.map((EbDeviceState s) => s.scene.mode)),
      colour: Common<ColourIntent>.from(shown),
      timerDeadline: _commonDeadline(
        states.map((EbDeviceState s) => s.timerDeadline).toList(),
      ),
      kelvin: kelvins.isEmpty ? null : kelvins.average,
      fireworkColorMode: colorMode(EbColorModeKind.firework),
      clubColorMode: colorMode(EbColorModeKind.club),
      policeColorMode: colorMode(EbColorModeKind.police),
      policeA: police(EbPoliceSlot.a),
      policeB: police(EbPoliceSlot.b),
      master: _ref.master,
    );
  }

  /// The pick while the light's colour is the change that sent it.
  static ColourIntent? _pickOf(FixtureStatus st) {
    final EbColorOrigin? origin = st.view?.colorOrigin;
    final ColourPick? pick = st.colourPick;
    return origin != null &&
            origin.byUser &&
            pick != null &&
            pick.seq == origin.seq
        ? pick.intent
        : null;
  }

  /// The colour a light shows as an intent: the pick while the light's
  /// colour is the change that sent it, else read from its channels.
  static ColourIntent _shownIntent(FixtureStatus st, Fixture f) =>
      _pickOf(st) ?? ColourEngine(f.whitePoints).decode(st.state!.scene.color);

  /// Timers firing within 2 s of each other count as one (the earliest).
  static Common<Duration> _commonDeadline(List<Duration?> deadlines) {
    if (deadlines.isEmpty || deadlines.every((Duration? d) => d == null)) {
      return const Common<Duration>.none();
    }
    if (deadlines.any((Duration? d) => d == null)) {
      return const Common<Duration>.mixed();
    }
    final List<Duration> all = deadlines.cast<Duration>();
    final Duration first = all.reduce(
      (Duration a, Duration b) => a < b ? a : b,
    );
    final Duration last = all.reduce((Duration a, Duration b) => a > b ? a : b);
    return last - first <= const Duration(seconds: 2)
        ? Common<Duration>.of(first)
        : const Common<Duration>.mixed();
  }
}
