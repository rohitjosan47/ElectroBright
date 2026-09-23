import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/ble/ble_constants.dart';
import '../../../../core/ble/ble_transport.dart';
import '../../../../core/ble/ble_dispatcher.dart';
import '../../../../core/ble/ble_protocol.dart';
import '../../../../core/utils/echo_suppressor.dart';
import '../../presets/data/preset_name_repository.dart';
import '../../presets/domain/preset_data.dart';
import '../domain/device_state.dart';
import '../../devices/application/device_library_notifier.dart';
import '../../../core/devices/device_profile.dart';

/// Provider for the BleTransport instance.
final bleTransportProvider = Provider<BleTransport>((ref) {
  throw UnimplementedError('Initialize bleTransportProvider in main.dart');
});

final bleDispatcherProvider = Provider<BleDispatcher>((ref) {
  final transport = ref.watch(bleTransportProvider);
  final dispatcher = BleDispatcher(transport);
  ref.onDispose(() => dispatcher.dispose());
  return dispatcher;
});

final echoSuppressorProvider = Provider<EchoSuppressor>((ref) {
  final suppressor = EchoSuppressor();
  ref.onDispose(() => suppressor.dispose());
  return suppressor;
});

// These providers deliberately watch ONLY the active device id / profile.
// Watching the whole library state rebuilt the DeviceNotifier (resetting all
// hardware state to defaults) on every rename, retype or timestamp update.
final presetNameRepositoryProvider = Provider<PresetNameRepository>((ref) {
  final activeId = ref.watch(deviceLibraryProvider.select((s) => s.activeDeviceId)) ?? 'legacy-default';
  final numPresets = ref.watch(deviceLibraryProvider.select((s) => s.activeProfile.numPresets));
  return PresetNameRepository(activeId, numPresets);
});

final deviceStateProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  final transport = ref.watch(bleTransportProvider);
  final dispatcher = ref.watch(bleDispatcherProvider);
  final echoSuppressor = ref.watch(echoSuppressorProvider);
  final presetRepo = ref.watch(presetNameRepositoryProvider);
  final profile = ref.watch(deviceLibraryProvider.select((s) => s.activeProfile));
  return DeviceNotifier(transport, dispatcher, echoSuppressor, presetRepo, profile);
});

class DeviceNotifier extends StateNotifier<DeviceState> {
  final BleTransport _transport;
  final BleDispatcher _dispatcher;
  final EchoSuppressor _echoSuppressor;
  final PresetNameRepository _presetNameRepo;
  final DeviceProfile _profile;
  StreamSubscription? _notificationSub;
  StreamSubscription? _connectionSub;
  Timer? _activePresetDebounceTimer;
  Timer? _localSleepTimer;
  Timer? _reconciliationTimer;
  late final ValueNotifier<LiveColorState> liveColor;

  /// True once the hardware has answered PRESET_LIST in this session; from then
  /// on the hardware list is authoritative over locally cached presets.
  bool _hardwarePresetsKnown = false;

  /// Slot whose PRESET_LOAD is in flight; the next STATUS reflects that preset
  /// and is used to refresh its cached snapshot.
  int? _pendingPresetLoadId;

  DeviceNotifier(
    this._transport,
    this._dispatcher,
    this._echoSuppressor,
    this._presetNameRepo,
    this._profile,
  ) : super(DeviceState.initial(_profile)) {
    liveColor = ValueNotifier(LiveColorState(
      red: state.red,
      green: state.green,
      blue: state.blue,
      white: state.white,
      brightness: state.brightness,
    ));
    _listenToTransport();
    _loadPersistedPresets();
    // The notifier can be (re)created while a link is already up (e.g. after a
    // device is added or the active device changes). The connect listener only
    // fires on a transition, so sync explicitly here.
    if (_transport.isConnected) _requestFullSync();
  }

  void _requestFullSync() {
    _dispatcher.dispatch(BleProtocol.requestStatus());
    _dispatcher.dispatch(BleProtocol.requestModeSettings());
    _dispatcher.dispatch(BleProtocol.requestPresetList());
    _dispatcher.dispatch(BleProtocol.getVersion());
    _dispatcher.dispatch(BleProtocol.requestCaps());
  }

  void _scheduleReconciliation({Duration delay = const Duration(milliseconds: 300)}) {
    _reconciliationTimer?.cancel();
    _reconciliationTimer = Timer(delay, () {
      if (mounted) _dispatcher.dispatch(BleProtocol.requestStatus());
    });
  }

  static const _toggleHold = Duration(milliseconds: BleConstants.toggleSuppressionMs);

  bool _requireConnection() {
    if (_transport.isConnected) return true;
    state = state.copyWith(lastError: 'Not connected to a light');
    return false;
  }

  @override
  set state(DeviceState value) {
    final oldActiveId = state.activePresetId;
    super.state = value;
    if (value.activePresetId != oldActiveId) {
      _debouncePersistActivePresetId(value.activePresetId);
    }
  }

  void _debouncePersistActivePresetId(int? id) {
    _activePresetDebounceTimer?.cancel();
    _activePresetDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _presetNameRepo.saveActivePresetId(id);
    });
  }

  Future<void> _loadPersistedPresets() async {
    final names = await _presetNameRepo.loadPresetNames();
    final snapshots = await _presetNameRepo.loadPresetSnapshots();
    final savedIds = await _presetNameRepo.loadSavedPresetIds();
    final savedActiveId = await _presetNameRepo.loadActivePresetId();

    if (!mounted) return;

    final mergedNames = Map<int, String>.from(state.presetNames);
    names.forEach((k, v) {
      if (v.trim().isNotEmpty) mergedNames[k] = v;
    });

    final mergedSnapshots = Map<int, PresetData>.from(state.presetSnapshots);
    snapshots.forEach((k, v) {
      mergedSnapshots[k] = v;
    });

    // Which slots are occupied: the hardware list wins if it already arrived;
    // otherwise use the persisted list from the last session (offline view).
    final Set<int> saved;
    if (_hardwarePresetsKnown) {
      saved = Set<int>.from(state.savedPresets);
    } else {
      saved = savedIds ?? mergedSnapshots.keys.toSet();
    }
    mergedNames.removeWhere((k, _) => !saved.contains(k));
    mergedSnapshots.removeWhere((k, _) => !saved.contains(k));

    // Only restore the highlight; the live color/mode come from the hardware's
    // STATUS, never from a cached snapshot (which may no longer match reality).
    state = state.copyWith(
      presetNames: mergedNames,
      presetSnapshots: mergedSnapshots,
      savedPresets: saved,
      activePresetId: (savedActiveId != null && saved.contains(savedActiveId)) ? savedActiveId : null,
      clearActivePreset: savedActiveId == null || !saved.contains(savedActiveId),
    );
  }

  void _listenToTransport() {
    _notificationSub = _transport.notificationsStream.listen(_handleIncomingNotification);
    _connectionSub = _transport.connectionStateStream.listen((connState) {
      if (connState == DeviceConnectionState.connected) {
        _requestFullSync();
      } else if (connState == DeviceConnectionState.disconnected) {
        _hardwarePresetsKnown = false;
        _pendingPresetLoadId = null;
      }
    });
  }

  void _startLocalSleepTimer() {
    _localSleepTimer?.cancel();
    _localSleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (state.timerActive && state.timerRemainingSec != null && state.timerRemainingSec! > 0) {
        state = state.copyWith(timerRemainingSec: state.timerRemainingSec! - 1);
      } else {
        timer.cancel();
        if (state.timerRemainingSec == 0 && state.timerActive) {
          state = state.copyWith(timerActive: false, isSleeping: true);
        }
      }
    });
  }

  void _handleIncomingNotification(String line) {
    // 1. Check for STATUS broadcast
    final status = BleProtocol.parseStatus(line);
    if (status != null) {
      final newSpeeds = List<int>.from(state.modeSpeed);
      final newFreqs = List<int>.from(state.modeFrequency);
      if (status.mode >= 1 && status.mode <= newSpeeds.length) {
        newSpeeds[status.mode - 1] = status.currentModeSpeed;
        newFreqs[status.mode - 1] = status.currentModeFrequency;
      }

      final policeA = status.policeColorA ??
          [state.policeColorAR, state.policeColorAG, state.policeColorAB, state.policeColorAW];
      final policeB = status.policeColorB ??
          [state.policeColorBR, state.policeColorBG, state.policeColorBB, state.policeColorBW];

      // The first STATUS after a PRESET_LOAD is the hardware's version of that
      // preset: refresh the cached snapshot from it. Any other STATUS must NOT
      // touch snapshots (it reflects live edits, not the saved preset).
      var updatedSnapshots = state.presetSnapshots;
      final loadedId = _pendingPresetLoadId;
      if (loadedId != null) {
        _pendingPresetLoadId = null;
        final map = Map<int, PresetData>.from(state.presetSnapshots);
        final snapshot = PresetData.fromValues(
          red: status.red,
          green: status.green,
          blue: status.blue,
          white: status.white,
          brightness: status.brightness,
          mode: status.mode,
          modeSpeed: newSpeeds,
          modeFrequency: newFreqs,
          fireworkColorMode: status.fireworkColorMode,
          clubColorMode: status.clubColorMode,
          policeColorMode: status.policeColorMode,
          policeColorAR: policeA[0],
          policeColorAG: policeA[1],
          policeColorAB: policeA[2],
          policeColorAW: policeA[3],
          policeColorBR: policeB[0],
          policeColorBG: policeB[1],
          policeColorBB: policeB[2],
          policeColorBW: policeB[3],
        );
        map[loadedId] = snapshot;
        updatedSnapshots = map;
        _presetNameRepo.savePresetSnapshot(loadedId, snapshot);
      }

      if (status.timerActive == true) {
        _startLocalSleepTimer();
      } else {
        _localSleepTimer?.cancel();
      }

      // APP-9 Post-Drag Reconciliation Policy:
      // We unconditionally accept the device's authoritative state (if the lock is free).
      // If a terminal commit packet was dropped due to BLE congestion, the hardware
      // will echo back the old state. The UI will instantly snap back, providing
      // truthful visual feedback to the user that the command failed.
      // (Silent background retries mask connectivity issues and create divergent state).
      state = state.copyWith(
        red: _echoSuppressor.isLocked('rgbw') ? state.red : status.red,
        green: _echoSuppressor.isLocked('rgbw') ? state.green : status.green,
        blue: _echoSuppressor.isLocked('rgbw') ? state.blue : status.blue,
        white: _echoSuppressor.isLocked('rgbw') ? state.white : status.white,
        brightness: _echoSuppressor.isLocked('brightness') ? state.brightness : status.brightness,
        mode: status.mode,
        modeSpeed: newSpeeds,
        modeFrequency: newFreqs,
        fireworkColorMode: status.fireworkColorMode,
        clubColorMode: status.clubColorMode,
        policeColorMode: status.policeColorMode,
        policeColorAR: policeA[0],
        policeColorAG: policeA[1],
        policeColorAB: policeA[2],
        policeColorAW: policeA[3],
        policeColorBR: policeB[0],
        policeColorBG: policeB[1],
        policeColorBB: policeB[2],
        policeColorBW: policeB[3],
        presetSnapshots: updatedSnapshots,
        isSleeping: _echoSuppressor.isLocked('sleep') ? state.isSleeping : (status.sleeping ?? state.isSleeping),
        soundEnabled: _echoSuppressor.isLocked('sound') ? state.soundEnabled : (status.soundEnabled ?? state.soundEnabled),
        timerActive: status.timerActive ?? state.timerActive,
        timerRemainingSec: status.timerRemainingSec ?? state.timerRemainingSec,
      );
      
      if (!_echoSuppressor.isLocked('rgbw') && !_echoSuppressor.isLocked('brightness')) {
        liveColor.value = LiveColorState(
          red: state.red,
          green: state.green,
          blue: state.blue,
          white: state.white,
          brightness: state.brightness,
        );
      }
      return;
    }

    // 2. Check for MODE_SETTINGS
    final modeSettings = BleProtocol.parseModeSettings(line);
    if (modeSettings != null) {
      final newSpeeds = List<int>.from(state.modeSpeed);
      final newFreqs = List<int>.from(state.modeFrequency);
      modeSettings.forEach((modeId, values) {
        if (modeId >= 1 && modeId <= newSpeeds.length) {
          newSpeeds[modeId - 1] = values['speed'] ?? newSpeeds[modeId - 1];
          newFreqs[modeId - 1] = values['frequency'] ?? newFreqs[modeId - 1];
        }
      });
      state = state.copyWith(modeSpeed: newSpeeds, modeFrequency: newFreqs);
      return;
    }

    // 3. Check for PRESETS list
    final presets = BleProtocol.parsePresets(line);
    if (presets != null) {
      _applyHardwarePresetList(presets);
      return;
    }

    // 4. Check for VERSION
    final version = BleProtocol.parseVersion(line);
    if (version != null) {
      state = state.copyWith(firmwareVersion: version);
      return;
    }

    // 4.5 Check for CAPS
    final caps = BleProtocol.parseCaps(line);
    if (caps != null) {
      final protocol = int.tryParse(caps['PROTOCOL'] ?? '') ?? 0;
      state = state.copyWith(supportsBinaryFastPath: protocol >= 1);
      return;
    }

    // 5. Check for errors
    final error = BleProtocol.parseError(line);
    if (error != null) {
      if (error.startsWith('PRESET_EMPTY')) {
        _pendingPresetLoadId = null;
        final parts = error.split(':');
        final failedId = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (failedId != null) {
          final updatedSaved = Set<int>.from(state.savedPresets)..remove(failedId);
          final updatedSnapshots = Map<int, PresetData>.from(state.presetSnapshots)..remove(failedId);
          state = state.copyWith(
            savedPresets: updatedSaved,
            presetSnapshots: updatedSnapshots,
            clearActivePreset: state.activePresetId == failedId,
          );
        }
        _dispatcher.dispatch(BleProtocol.requestStatus());
      }
      state = state.copyWith(lastError: 'ERROR:$error');
      return;
    }
  }



  /// Makes the hardware's occupied-slot list authoritative: cached names and
  /// snapshots for slots the device does not have are dropped (and forgotten
  /// on disk), so an emptied slot never resurrects a stale name or scene.
  void _applyHardwarePresetList(Set<int> presets) {
    _hardwarePresetsKnown = true;
    final staleIds = {...state.presetSnapshots.keys, ...state.presetNames.keys}
        .where((id) => !presets.contains(id))
        .toSet();
    final names = Map<int, String>.from(state.presetNames)..removeWhere((k, _) => staleIds.contains(k));
    final snapshots = Map<int, PresetData>.from(state.presetSnapshots)..removeWhere((k, _) => staleIds.contains(k));
    final activeStillValid = state.activePresetId != null && presets.contains(state.activePresetId);
    state = state.copyWith(
      savedPresets: presets,
      presetNames: names,
      presetSnapshots: snapshots,
      clearActivePreset: !activeStillValid,
    );
    for (final id in staleIds) {
      _presetNameRepo.resetPresetName(id);
      _presetNameRepo.deletePresetSnapshot(id);
    }
    _presetNameRepo.saveSavedPresetIds(presets);
  }

  // --- User Intents & Hardware Dispatch ---

  void setRgbw(int r, int g, int b, int w, {bool continuous = true}) {
    liveColor.value = LiveColorState(
      red: r, green: g, blue: b, white: w, brightness: liveColor.value.brightness
    );
    if (continuous) {
      _echoSuppressor.acquireLock('rgbw');
      state = state.copyWith(red: r, green: g, blue: b, white: w, clearActivePreset: true);
      if (state.supportsBinaryFastPath) {
        _dispatcher.dispatchBinary(
          BleProtocol.encodeRgbwBrightnessBinary(r, g, b, w, liveColor.value.brightness),
          priority: CommandPriority.continuous,
          identity: 'color',
        );
      } else {
        _dispatcher.dispatch(
          BleProtocol.setRgbw(r, g, b, w),
          priority: CommandPriority.continuous,
          identity: 'rgbw',
        );
      }
    } else {
      _echoSuppressor.releaseLock('rgbw');
      state = state.copyWith(red: r, green: g, blue: b, white: w, clearActivePreset: true);
      if (state.supportsBinaryFastPath) {
        _dispatcher.dispatchBinary(
          BleProtocol.encodeRgbwBrightnessBinary(r, g, b, w, liveColor.value.brightness),
          priority: CommandPriority.immediate,
          identity: 'color',
        );
      } else {
        _dispatcher.dispatch(BleProtocol.setRgbw(r, g, b, w));
      }
      _scheduleReconciliation();
    }
  }

  void setBrightness(int br, {bool continuous = true}) {
    liveColor.value = LiveColorState(
      red: liveColor.value.red, green: liveColor.value.green, 
      blue: liveColor.value.blue, white: liveColor.value.white, brightness: br
    );
    if (continuous) {
      _echoSuppressor.acquireLock('brightness');
      state = state.copyWith(brightness: br, clearActivePreset: true);
      if (state.supportsBinaryFastPath) {
        _dispatcher.dispatchBinary(
          BleProtocol.encodeRgbwBrightnessBinary(
            liveColor.value.red, liveColor.value.green, liveColor.value.blue, liveColor.value.white, br
          ),
          priority: CommandPriority.continuous,
          identity: 'color',
        );
      } else {
        _dispatcher.dispatch(
          BleProtocol.setBrightness(br),
          priority: CommandPriority.continuous,
          identity: 'brightness',
        );
      }
    } else {
      _echoSuppressor.releaseLock('brightness');
      state = state.copyWith(brightness: br, clearActivePreset: true);
      if (state.supportsBinaryFastPath) {
        _dispatcher.dispatchBinary(
          BleProtocol.encodeRgbwBrightnessBinary(
            liveColor.value.red, liveColor.value.green, liveColor.value.blue, liveColor.value.white, br
          ),
          priority: CommandPriority.immediate,
          identity: 'color',
        );
      } else {
        _dispatcher.dispatch(BleProtocol.setBrightness(br));
      }
      _scheduleReconciliation();
    }
  }

  void setMode(int mode) {
    state = state.copyWith(mode: mode, clearActivePreset: true);
    liveColor.value = LiveColorState(
      red: state.red,
      green: state.green,
      blue: state.blue,
      white: state.white,
      brightness: state.brightness,
    );
    _dispatcher.dispatch(BleProtocol.setMode(mode));
  }

  void setSpeed(int speed, {bool continuous = true}) {
    final newSpeeds = List<int>.from(state.modeSpeed);
    newSpeeds[state.mode - 1] = speed;

    if (continuous) {
      _echoSuppressor.acquireLock('speed');
      state = state.copyWith(modeSpeed: newSpeeds, clearActivePreset: true);
      _dispatcher.dispatch(
        BleProtocol.setSpeed(speed),
        priority: CommandPriority.continuous,
        identity: 'speed',
      );
    } else {
      _echoSuppressor.releaseLock('speed');
      state = state.copyWith(modeSpeed: newSpeeds, clearActivePreset: true);
      _dispatcher.flushPending();
      _dispatcher.dispatch(BleProtocol.setSpeed(speed));
    }
  }

  void setFrequency(int freq, {bool continuous = true}) {
    final newFreqs = List<int>.from(state.modeFrequency);
    newFreqs[state.mode - 1] = freq;

    if (continuous) {
      _echoSuppressor.acquireLock('freq');
      state = state.copyWith(modeFrequency: newFreqs, clearActivePreset: true);
      _dispatcher.dispatch(
        BleProtocol.setFrequency(freq),
        priority: CommandPriority.continuous,
        identity: 'freq',
      );
    } else {
      _echoSuppressor.releaseLock('freq');
      state = state.copyWith(modeFrequency: newFreqs, clearActivePreset: true);
      _dispatcher.flushPending();
      _dispatcher.dispatch(BleProtocol.setFrequency(freq));
    }
  }

  void setFireworkColorMode(int val) {
    state = state.copyWith(fireworkColorMode: val, clearActivePreset: true);
    _dispatcher.dispatch(BleProtocol.setFireworkColorMode(val));
  }

  void setClubColorMode(int val) {
    state = state.copyWith(clubColorMode: val, clearActivePreset: true);
    _dispatcher.dispatch(BleProtocol.setClubColorMode(val));
  }

  void setPoliceColorMode(int val) {
    state = state.copyWith(policeColorMode: val, clearActivePreset: true);
    _dispatcher.dispatch(BleProtocol.setPoliceColorMode(val));
  }

  void setPoliceColorA(int r, int g, int b, int w) {
    state = state.copyWith(
      policeColorAR: r,
      policeColorAG: g,
      policeColorAB: b,
      policeColorAW: w,
      clearActivePreset: true,
    );
    _dispatcher.dispatch(BleProtocol.setPoliceColorA(r, g, b, w));
  }

  void setPoliceColorB(int r, int g, int b, int w) {
    state = state.copyWith(
      policeColorBR: r,
      policeColorBG: g,
      policeColorBB: b,
      policeColorBW: w,
      clearActivePreset: true,
    );
    _dispatcher.dispatch(BleProtocol.setPoliceColorB(r, g, b, w));
  }

  void savePreset(int id) {
    final snapshot = PresetData.fromValues(
      red: state.red,
      green: state.green,
      blue: state.blue,
      white: state.white,
      brightness: state.brightness,
      mode: state.mode,
      modeSpeed: state.modeSpeed,
      modeFrequency: state.modeFrequency,
      fireworkColorMode: state.fireworkColorMode,
      clubColorMode: state.clubColorMode,
      policeColorMode: state.policeColorMode,
      policeColorAR: state.policeColorAR,
      policeColorAG: state.policeColorAG,
      policeColorAB: state.policeColorAB,
      policeColorAW: state.policeColorAW,
      policeColorBR: state.policeColorBR,
      policeColorBG: state.policeColorBG,
      policeColorBB: state.policeColorBB,
      policeColorBW: state.policeColorBW,
    );

    final wasEmpty = !state.savedPresets.contains(id);
    final updatedSaved = Set<int>.from(state.savedPresets)..add(id);
    final updatedSnapshots = Map<int, PresetData>.from(state.presetSnapshots)..[id] = snapshot;
    // A new preset in a previously empty slot starts with the default name.
    final updatedNames = Map<int, String>.from(state.presetNames);
    if (wasEmpty) updatedNames.remove(id);

    state = state.copyWith(
      savedPresets: updatedSaved,
      presetSnapshots: updatedSnapshots,
      presetNames: updatedNames,
      activePresetId: id,
    );

    _dispatcher.dispatch(BleProtocol.savePreset(id));
    _dispatcher.dispatch(BleProtocol.requestPresetList());
    if (wasEmpty) _presetNameRepo.resetPresetName(id);
    _presetNameRepo.savePresetSnapshot(id, snapshot);
    _presetNameRepo.saveSavedPresetIds(updatedSaved);
  }

  void loadPreset(int id) {
    // 1. Release all slider locks immediately so incoming preset values apply cleanly
    _echoSuppressor.releaseAll();

    // 2. Optimistically apply cached preset parameters immediately to entire app UI
    if (state.presetSnapshots.containsKey(id)) {
      final p = state.presetSnapshots[id]!;
      final newSpeeds = List<int>.from(p.modeSpeed);
      final newFreqs = List<int>.from(p.modeFrequency);

      state = state.copyWith(
        red: p.red,
        green: p.green,
        blue: p.blue,
        white: p.white,
        brightness: p.brightness,
        mode: p.mode,
        modeSpeed: newSpeeds,
        modeFrequency: newFreqs,
        fireworkColorMode: p.fireworkColorMode,
        clubColorMode: p.clubColorMode,
        policeColorMode: p.policeColorMode,
        policeColorAR: p.policeColorAR,
        policeColorAG: p.policeColorAG,
        policeColorAB: p.policeColorAB,
        policeColorAW: p.policeColorAW,
        policeColorBR: p.policeColorBR,
        policeColorBG: p.policeColorBG,
        policeColorBB: p.policeColorBB,
        policeColorBW: p.policeColorBW,
        isSleeping: false,
        activePresetId: id,
      );
    } else {
      state = state.copyWith(activePresetId: id);
    }

    // 3. Sync liveColor so binary fast-path packets use the preset's values
    liveColor.value = LiveColorState(
      red: state.red,
      green: state.green,
      blue: state.blue,
      white: state.white,
      brightness: state.brightness,
    );

    // 4. Dispatch load to hardware. The firmware answers a successful load
    //    with STATUS (used to refresh this slot's snapshot) or PRESET_EMPTY.
    _pendingPresetLoadId = id;
    _dispatcher.dispatch(BleProtocol.loadPreset(id));
  }

  void deletePreset(int id) {
    final updatedSaved = Set<int>.from(state.savedPresets)..remove(id);
    final updatedSnapshots = Map<int, PresetData>.from(state.presetSnapshots)..remove(id);
    final updatedNames = Map<int, String>.from(state.presetNames)..remove(id);
    final isCurrentActive = state.activePresetId == id;

    state = state.copyWith(
      presetNames: updatedNames,
      savedPresets: updatedSaved,
      presetSnapshots: updatedSnapshots,
      clearActivePreset: isCurrentActive,
    );

    _dispatcher.dispatch(BleProtocol.deletePreset(id));
    _presetNameRepo.resetPresetName(id);
    _presetNameRepo.deletePresetSnapshot(id);
    _presetNameRepo.saveSavedPresetIds(updatedSaved);
  }

  Future<void> renamePreset(int slotId, String newName) async {
    final updated = Map<int, String>.from(state.presetNames);
    final clean = newName.trim();
    if (clean.isNotEmpty) {
      updated[slotId] = clean;
    } else {
      updated[slotId] = 'Preset ${slotId + 1}';
    }
    state = state.copyWith(presetNames: updated);
    await _presetNameRepo.savePresetName(slotId, clean);
  }

  void toggleSleep() {
    if (!_requireConnection()) return;
    final newSleep = !state.isSleeping;
    // Short timed hold so a STATUS already in flight cannot flip the button
    // back; reconciliation after the hold confirms the device's real state.
    _echoSuppressor.suppressFor('sleep', _toggleHold);
    if (newSleep) {
      // Firmware SLEEP also cancels any running timer.
      _localSleepTimer?.cancel();
      state = state.copyWith(isSleeping: true, timerActive: false, timerRemainingSec: 0);
      _dispatcher.dispatch(BleProtocol.sleep());
    } else {
      state = state.copyWith(isSleeping: false);
      _dispatcher.dispatch(BleProtocol.wake());
    }
    _scheduleReconciliation(delay: _toggleHold + const Duration(milliseconds: 100));
  }

  void toggleSound() {
    if (!_requireConnection()) return;
    _echoSuppressor.suppressFor('sound', _toggleHold);
    final newSound = !state.soundEnabled;
    state = state.copyWith(soundEnabled: newSound);
    if (newSound) {
      _dispatcher.dispatch(BleProtocol.soundOn());
    } else {
      _dispatcher.dispatch(BleProtocol.soundOff());
    }
    _scheduleReconciliation(delay: _toggleHold + const Duration(milliseconds: 100));
  }

  void setTimer(int seconds) {
    if (!_requireConnection()) return;
    state = state.copyWith(
      timerActive: seconds > 0,
      timerSecondsSet: seconds,
      timerRemainingSec: seconds,
    );
    _dispatcher.dispatch(BleProtocol.setTimer(seconds));
    if (seconds > 0) {
      _startLocalSleepTimer();
    } else {
      _localSleepTimer?.cancel();
    }
  }

  void factoryReset() {
    if (!_requireConnection()) return;
    _presetNameRepo.wipeAll();
    _localSleepTimer?.cancel();
    _echoSuppressor.releaseAll();
    _pendingPresetLoadId = null;
    _hardwarePresetsKnown = false;
    // Connection-level facts (firmware version, protocol caps) survive a reset.
    state = DeviceState.initial(_profile).copyWith(
      firmwareVersion: state.firmwareVersion,
      supportsBinaryFastPath: state.supportsBinaryFastPath,
    );
    liveColor.value = LiveColorState(
      red: state.red,
      green: state.green,
      blue: state.blue,
      white: state.white,
      brightness: state.brightness,
    );
    _dispatcher.dispatch(BleProtocol.factoryReset());
    _dispatcher.dispatch(BleProtocol.requestStatus());
    _dispatcher.dispatch(BleProtocol.requestModeSettings());
    _dispatcher.dispatch(BleProtocol.requestPresetList());
  }

  void clearError() {
    state = state.copyWith(clearLastError: true);
  }

  @override
  void dispose() {
    _activePresetDebounceTimer?.cancel();
    _localSleepTimer?.cancel();
    _reconciliationTimer?.cancel();
    _notificationSub?.cancel();
    _connectionSub?.cancel();
    liveColor.dispose();
    super.dispose();
  }
}
