import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../connection/application/connection_notifier.dart';
import '../application/device_notifier.dart';
import 'widgets/aura_background.dart';
import 'widgets/header_bar.dart';
import 'widgets/master_brightness_card.dart';
import 'widgets/rgbw_palette_card.dart';
import 'widgets/mode_carousel.dart';
import 'widgets/contextual_controls_card.dart';
import 'widgets/preset_grid.dart';
import '../../settings/presentation/settings_sheet.dart';
import '../../devices/application/device_library_notifier.dart';
import '../../devices/presentation/device_library_sheet.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _isInteractingWithControl = false;

  void _setInteracting(bool interacting) {
    if (_isInteractingWithControl != interacting) {
      setState(() {
        _isInteractingWithControl = interacting;
      });
    }
  }

  void _openDeviceLibrary(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const DeviceLibrarySheet(),
    );
  }

  void _openSettings(BuildContext context) {
    final deviceState = ref.read(deviceStateProvider);
    final notifier = ref.read(deviceStateProvider.notifier);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SettingsSheet(
        profile: ref.read(deviceLibraryProvider).activeProfile,
        soundEnabled: deviceState.soundEnabled,
        timerActive: deviceState.timerActive,
        timerMinutesSet: deviceState.timerMinutesSet,
        timerRemainingSec: deviceState.timerRemainingSec,
        firmwareVersion: deviceState.firmwareVersion,
        onToggleSound: () => notifier.toggleSound(),
        onSetTimer: (mins) => notifier.setTimer(mins),
        onFactoryReset: () {
          notifier.factoryReset();
          final activeLabel = ref.read(deviceLibraryProvider).activeDevice?.label ?? 'device';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$activeLabel restored to factory defaults.'),
              backgroundColor: AppColors.cardSurface,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DeviceState>(deviceStateProvider, (previous, next) {
      if (next.lastError != null && previous?.lastError != next.lastError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.lastError!),
            backgroundColor: Colors.redAccent,
          ),
        );
        ref.read(deviceStateProvider.notifier).clearError();
      }
    });

    final deviceState = ref.watch(deviceStateProvider);
    final connectionState = ref.watch(connectionProvider);
    final libraryState = ref.watch(deviceLibraryProvider);
    final notifier = ref.read(deviceStateProvider.notifier);
    final profile = libraryState.activeProfile;

    return Scaffold(
      body: AuraBackground(
        activeColor: deviceState.activeRgbColor,
        child: SafeArea(
          child: CustomScrollView(
            physics: _isInteractingWithControl
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            slivers: [
              // 1. Top Header Bar
              SliverToBoxAdapter(
                child: HeaderBar(
                  connectionState: connectionState.state,
                  activeDeviceLabel: libraryState.activeDevice?.label,
                  isSleeping: deviceState.isSleeping,
                  onConnectionTap: () => _openDeviceLibrary(context),
                  onPowerTap: () => notifier.toggleSleep(),
                  onSettingsTap: () => _openSettings(context),
                ),
              ),

              // 2. Master Brightness Section
              SliverToBoxAdapter(
                child: MasterBrightnessCard(
                  brightness: deviceState.brightness,
                  onInteractionChanged: _setInteracting,
                  onBrightnessChanged: (val, continuous) {
                    notifier.setBrightness(val, continuous: continuous);
                  },
                ),
              ),

              // 3. Core RGBW Color Palette
              SliverToBoxAdapter(
                child: RgbwPaletteCard(
                  red: deviceState.red,
                  green: deviceState.green,
                  blue: deviceState.blue,
                  white: deviceState.white,
                  onInteractionChanged: _setInteracting,
                  onRgbwChanged: (r, g, b, w, continuous) {
                    notifier.setRgbw(r, g, b, w, continuous: continuous);
                  },
                ),
              ),

              // 4. 13-Mode Selector Carousel
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: ModeCarousel(
                    modes: profile.modes,
                    activeModeId: deviceState.mode,
                    onModeSelected: (modeId) => notifier.setMode(modeId),
                  ),
                ),
              ),

              // 5. Contextual Controls (Speed, Freq, Auto/Manual, Police Dual Pickers)
              SliverToBoxAdapter(
                child: ContextualControlsCard(
                  deviceState: deviceState,
                  onSpeedChanged: (spd, continuous) {
                    notifier.setSpeed(spd, continuous: continuous);
                  },
                  onFrequencyChanged: (frq, continuous) {
                    notifier.setFrequency(frq, continuous: continuous);
                  },
                  onFireworkColorModeChanged: (val) {
                    notifier.setFireworkColorMode(val);
                  },
                  onClubColorModeChanged: (val) {
                    notifier.setClubColorMode(val);
                  },
                  onPoliceColorModeChanged: (val) {
                    notifier.setPoliceColorMode(val);
                  },
                  onPoliceColorAChanged: (r, g, b, w) {
                    notifier.setPoliceColorA(r, g, b, w);
                  },
                  onPoliceColorBChanged: (r, g, b, w) {
                    notifier.setPoliceColorB(r, g, b, w);
                  },
                ),
              ),

              // 6. Preset Vault
              SliverToBoxAdapter(
                child: PresetGrid(
                  numPresets: profile.numPresets,
                  savedPresets: deviceState.savedPresets,
                  presetNames: deviceState.presetNames,
                  activePresetId: deviceState.activePresetId,
                  onLoadPreset: (slotId) {
                    notifier.loadPreset(slotId);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('✨ Loaded ${deviceState.getPresetName(slotId)} (Slot ${slotId + 1})'),
                        duration: const Duration(seconds: 1),
                        backgroundColor: AppColors.cardSurface,
                      ),
                    );
                  },
                  onSavePreset: (slotId) {
                    notifier.savePreset(slotId);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Saved scene to ${deviceState.getPresetName(slotId)}'),
                        duration: const Duration(seconds: 1),
                        backgroundColor: AppColors.cyanAccent,
                      ),
                    );
                  },
                  onDeletePreset: (slotId) {
                    notifier.deletePreset(slotId);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Cleared Preset ${slotId + 1}'),
                        duration: const Duration(seconds: 1),
                        backgroundColor: AppColors.cardSurface,
                      ),
                    );
                  },
                  onRenamePreset: (slotId, newName) {
                    notifier.renamePreset(slotId, newName);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Renamed Slot ${slotId + 1} to "$newName"'),
                        duration: const Duration(seconds: 1),
                        backgroundColor: AppColors.cyanAccent,
                      ),
                    );
                  },
                ),
              ),

              // Bottom padding for scroll comfort
              const SliverToBoxAdapter(
                child: SizedBox(height: 32),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
