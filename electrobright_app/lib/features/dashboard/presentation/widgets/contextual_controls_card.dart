import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../domain/mode_definition.dart';
import '../../domain/device_state.dart';
import 'police_dual_picker.dart';

class ContextualControlsCard extends StatelessWidget {
  final DeviceState deviceState;
  final Function(int speed, bool continuous) onSpeedChanged;
  final Function(int freq, bool continuous) onFrequencyChanged;
  final ValueChanged<int> onFireworkColorModeChanged;
  final ValueChanged<int> onClubColorModeChanged;
  final ValueChanged<int> onPoliceColorModeChanged;
  final Function(int r, int g, int b, int w) onPoliceColorAChanged;
  final Function(int r, int g, int b, int w) onPoliceColorBChanged;

  const ContextualControlsCard({
    super.key,
    required this.deviceState,
    required this.onSpeedChanged,
    required this.onFrequencyChanged,
    required this.onFireworkColorModeChanged,
    required this.onClubColorModeChanged,
    required this.onPoliceColorModeChanged,
    required this.onPoliceColorAChanged,
    required this.onPoliceColorBChanged,
  });

  @override
  Widget build(BuildContext context) {
    final modeDef = ModeDefinition.getById(deviceState.mode);

    // If mode has no contextual parameters (e.g., Solid Color), hide card
    if (!modeDef.hasSpeed && !modeDef.hasFrequency && !modeDef.hasColorMode) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.all(20.0),
        decoration: AppTheme.glassBoxDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.tune_rounded,
                      color: AppColors.cyanAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${modeDef.name} Settings',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Speed Slider
            if (modeDef.hasSpeed)
              _buildStepSlider(
                context: context,
                label: 'Animation Speed',
                icon: Icons.speed_rounded,
                value: deviceState.currentSpeed,
                min: 1,
                max: 10,
                accentColor: AppColors.cyanAccent,
                onChanged: (val) => onSpeedChanged(val, true),
                onChangeEnd: (val) => onSpeedChanged(val, false),
              ),

            // Frequency Slider
            if (modeDef.hasFrequency)
              _buildStepSlider(
                context: context,
                label: 'Frequency / Density',
                icon: Icons.graphic_eq_rounded,
                value: deviceState.currentFrequency,
                min: 1,
                max: 10,
                accentColor: AppColors.pinkAccent,
                onChanged: (val) => onFrequencyChanged(val, true),
                onChangeEnd: (val) => onFrequencyChanged(val, false),
              ),

            // Mode-specific Color Mode Switches
            if (modeDef.hasColorMode) ...[
              const Divider(color: AppColors.cardBorder, height: 24),
              _buildColorModeToggle(context, modeDef),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStepSlider({
    required BuildContext context,
    required String label,
    required IconData icon,
    required int value,
    required int min,
    required int max,
    required Color accentColor,
    required ValueChanged<int> onChanged,
    required ValueChanged<int> onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: accentColor),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.cardSurfaceSecondary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$value / $max',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: accentColor,
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accentColor,
              inactiveTrackColor: AppColors.cardSurfaceSecondary,
              thumbColor: Colors.white,
              overlayColor: accentColor.withOpacity(0.2),
              trackHeight: 6.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9.0),
            ),
            child: Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min,
              onChanged: (val) {
                HapticService.lightTick();
                onChanged(val.round());
              },
              onChangeEnd: (val) {
                onChangeEnd(val.round());
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorModeToggle(BuildContext context, ModeDefinition modeDef) {
    int currentModeValue = 0;
    ValueChanged<int> onToggle;
    String autoLabel = 'Auto Random';
    String manualLabel = 'Universal Color';

    if (modeDef.id == 4) {
      currentModeValue = deviceState.fireworkColorMode;
      onToggle = onFireworkColorModeChanged;
    } else if (modeDef.id == 9) {
      currentModeValue = deviceState.clubColorMode;
      onToggle = onClubColorModeChanged;
    } else {
      // Mode 12 (Police)
      currentModeValue = deviceState.policeColorMode;
      onToggle = onPoliceColorModeChanged;
      autoLabel = 'Red & Blue Strobe';
      manualLabel = 'Custom Dual Beacons';
    }

    final isManual = currentModeValue == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Color Pattern Engine',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  isManual ? manualLabel : autoLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.cyanAccent,
                  ),
                ),
              ],
            ),
            Switch(
              value: isManual,
              onChanged: (val) {
                HapticService.selectionTick();
                onToggle(val ? 0 : 1);
              },
            ),
          ],
        ),

        // If Mode 12 (Police) and Manual is ON, reveal the dual color pickers!
        if (modeDef.id == 12 && isManual)
          PoliceDualPicker(
            colorA: deviceState.policeColorA,
            colorB: deviceState.policeColorB,
            onColorAChanged: onPoliceColorAChanged,
            onColorBChanged: onPoliceColorBChanged,
          ),
      ],
    );
  }
}
