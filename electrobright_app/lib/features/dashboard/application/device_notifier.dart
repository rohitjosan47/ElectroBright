import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

final presetNameRepositoryProvider = Provider<PresetNameRepository>((ref) {
  final lib = ref.watch(deviceLibraryProvider);
  final activeId = lib.activeDeviceId ?? 'legacy-default';
  final numPresets = lib.activeProfile.numPresets;
  return PresetNameRepository(activeId, numPresets);
});

final deviceStateProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  final transport = ref.watch(bleTransportProvider);
  final dispatcher = ref.watch(bleDispatcherProvider);
  final echoSuppressor = ref.watch(echoSuppressorProvider);
  final presetRepo = ref.watch(presetNameRepositoryProvider);
  final profile = ref.watch(deviceLibraryProvider).activeProfile;
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

  DeviceNotifier(
    this._transport,
    this._dispatcher,
    this._echoSuppressor,
    this._presetNameRepo,
    this._profile,
  ) : super(DeviceState.initial(_profile)) {
    _listenToTransport();
    _loadPersistedPresets();
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

    final mergedSaved = Set<int>.from(state.savedPresets);
    if (savedIds != null) {
      mergedSaved.addAll(savedIds);
    }
    mergedSaved.addAll(mergedSnapshots.keys);

    if (savedActiveId != null && mergedSnapshots.containsKey(savedActiveId)) {
      final p = mergedSnapshots[savedActiveId]!;
      state = state.copyWith(
        presetNames: mergedNames,
        presetSnapshots: mergedSnapshots,
        savedPresets: mergedSaved,
        activePresetId: savedActiveId,
        red: p.red,
        green: p.green,
        blue: p.blue,
        white: p.white,
        brightness: p.brightness,
        mode: p.mode,
        modeSpeed: List<int>.from(p.modeSpeed),
        modeFrequency: List<int>.from(p.modeFrequency),
        fireworkColorMode: p.fireworkColorMode,
        clubColorMode: p.clubColorMode,
        policeColorMode: p.policeColorMode,
      );
    } else {
      state = state.copyWith(
        presetNames: mergedNames,
        presetSnapshots: mergedSnapshots,
        savedPresets: mergedSaved,
        activePresetId: savedActiveId,
      );
    }
  }

  void _listenToTransport() {
    _notificationSub = _transport.notificationsStream.listen(_handleIncomingNotification);
    _connectionSub = _transport.connectionStateStream.listen((connState) {
      if (connState == DeviceConnectionState.connected) {
        _dispatcher.dispatch(BleProtocol.requestStatus());
        _dispatcher.dispatch(BleProtocol.requestModeSettings());
        _dispatcher.dispatch(BleProtocol.requestPresetList());
        _dispatcher.dispatch(BleProtocol.getVersion());
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

      // If activePresetId is set, sync hardware status into local snapshot cache
      var updatedSnapshots = state.presetSnapshots;
      if (state.activePresetId != null) {
        final currentId = state.activePresetId!;
        final map = Map<int, PresetData>.from(state.presetSnapshots);
        map[currentId] = PresetData.fromValues(
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
          policeColorAR: state.policeColorAR,
          policeColorAG: state.policeColorAG,
          policeColorAB: state.policeColorAB,
          policeColorAW: state.policeColorAW,
          policeColorBR: state.policeColorBR,
          policeColorBG: state.policeColorBG,
          policeColorBB: state.policeColorBB,
          policeColorBW: state.policeColorBW,
        );
        updatedSnapshots = map;
      }

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
        presetSnapshots: updatedSnapshots,
        isSleeping: status.sleeping ?? state.isSleeping,
        soundEnabled: status.soundEnabled ?? state.soundEnabled,
        timerActive: status.timerActive ?? state.timerActive,
        timerRemainingSec: status.timerRemainingSec ?? state.timerRemainingSec,
      );
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
      state = state.copyWith(savedPresets: presets);
      return;
    }

    // 4. Check for VERSION
    final version = BleProtocol.parseVersion(line);
    if (version != null) {
      state = state.copyWith(firmwareVersion: version);
      return;
    }

    // 5. Check for errors
    final error = BleProtocol.parseError(line);
    if (error != null) {
      if (error.startsWith('PRESET_EMPTY')) {
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

  // --- User Intents & Hardware Dispatch ---

  void setRgbw(int r, int g, int b, int w, {bool continuous = true}) {
    if (continuous) {
      _echoSuppressor.acquireLock('rgbw');
      state = state.copyWith(red: r, green: g, blue: b, white: w, clearActivePreset: true);
      _dispatcher.dispatch(
        BleProtocol.setRgbw(r, g, b, w),
        priority: CommandPriority.continuous,
      );
    } else {
      _echoSuppressor.releaseLock('rgbw');
      state = state.copyWith(red: r, green: g, blue: b, white: w, clearActivePreset: true);
      _dispatcher.flushPending();
      _dispatcher.dispatch(BleProtocol.setRgbw(r, g, b, w));
    }
  }

  void setBrightness(int br, {bool continuous = true}) {
    if (continuous) {
      _echoSuppressor.acquireLock('brightness');
      state = state.copyWith(brightness: br, clearActivePreset: true);
      _dispatcher.dispatch(
        BleProtocol.setBrightness(br),
        priority: CommandPriority.continuous,
      );
    } else {
      _echoSuppressor.releaseLock('brightness');
      state = state.copyWith(brightness: br, clearActivePreset: true);
      _dispatcher.flushPending();
      _dispatcher.dispatch(BleProtocol.setBrightness(br));
    }
  }

  void setMode(int mode) {
    state = state.copyWith(mode: mode, clearActivePreset: true);
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

    final updatedSaved = Set<int>.from(state.savedPresets)..add(id);
    final updatedSnapshots = Map<int, PresetData>.from(state.presetSnapshots)..[id] = snapshot;

    state = state.copyWith(
      savedPresets: updatedSaved,
      presetSnapshots: updatedSnapshots,
      activePresetId: id,
    );

    _dispatcher.dispatch(BleProtocol.savePreset(id));
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

    // 3. Dispatch load to hardware (and query status)
    _dispatcher.dispatch(BleProtocol.loadPreset(id));
    _dispatcher.dispatch(BleProtocol.requestStatus());
  }

  void deletePreset(int id) {
    final updatedSaved = Set<int>.from(state.savedPresets)..remove(id);
    final updatedSnapshots = Map<int, PresetData>.from(state.presetSnapshots)..remove(id);
    final isCurrentActive = state.activePresetId == id;

    state = state.copyWith(
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
    final newSleep = !state.isSleeping;
    state = state.copyWith(isSleeping: newSleep);
    if (newSleep) {
      _dispatcher.dispatch(BleProtocol.sleep());
    } else {
      _dispatcher.dispatch(BleProtocol.wake());
    }
  }

  void toggleSound() {
    final newSound = !state.soundEnabled;
    state = state.copyWith(soundEnabled: newSound);
    if (newSound) {
      _dispatcher.dispatch(BleProtocol.soundOn());
    } else {
      _dispatcher.dispatch(BleProtocol.soundOff());
    }
  }

  void setTimer(int minutes) {
    state = state.copyWith(
      timerActive: minutes > 0,
      timerMinutesSet: minutes,
      timerRemainingSec: minutes * 60,
    );
    _dispatcher.dispatch(BleProtocol.setTimer(minutes));
  }

  void factoryReset() {
    _dispatcher.dispatch(BleProtocol.factoryReset());
    state = DeviceState.initial(_profile);
  }

  void clearError() {
    state = state.copyWith(clearLastError: true);
  }

  @override
  void dispose() {
    _activePresetDebounceTimer?.cancel();
    _notificationSub?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }
}
