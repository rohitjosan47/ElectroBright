import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../../../core/devices/device_profile.dart';
import '../../devices/presentation/device_library_sheet.dart';

class SettingsSheet extends StatefulWidget {
  final bool soundEnabled;
  final bool timerActive;
  final int timerMinutesSet;
  final int? timerRemainingSec;
  final String? firmwareVersion;
  final DeviceProfile profile;
  final VoidCallback onToggleSound;
  final ValueChanged<int> onSetTimer;
  final VoidCallback onFactoryReset;

  const SettingsSheet({
    super.key,
    required this.soundEnabled,
    required this.timerActive,
    required this.timerMinutesSet,
    this.timerRemainingSec,
    this.firmwareVersion,
    required this.profile,
    required this.onToggleSound,
    required this.onSetTimer,
    required this.onFactoryReset,
  });

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late double _sliderIndex;
  late bool _timerActive;

  static const List<int> _timerSteps = [
    5, 10, 15, 30, 60, 90, 120, 180, 240, 360, 480, 720, 1440
  ];

  @override
  void initState() {
    super.initState();
    _timerActive = widget.timerActive;
    
    int initialMin = widget.timerMinutesSet > 0 ? widget.timerMinutesSet : 30;
    int closestIndex = 0;
    for (int i = 0; i < _timerSteps.length; i++) {
      if (_timerSteps[i] >= initialMin) {
        closestIndex = i;
        break;
      }
    }
    _sliderIndex = closestIndex.toDouble();
  }

  void _showFactoryResetDialog(BuildContext context) {
    HapticService.alert();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.redAccent),
            SizedBox(width: 8),
            Text('Factory Reset', style: TextStyle(color: AppColors.textPrimary)),
          ],
        ),
        content: Text(
          'This will restore all ${widget.profile.numModes} modes, speeds, frequencies, and clear all ${widget.profile.numPresets} presets from the hardware. Are you sure?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop(); // Close dialog
              Navigator.of(context).pop(); // Close bottom sheet
              widget.onFactoryReset();
            },
            child: const Text('Confirm Reset', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
      decoration: const BoxDecoration(
        color: AppColors.backgroundElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Hardware Settings',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 18),

          // Manage My Lights
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: AppTheme.glassBoxDecoration(),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.library_books_rounded, color: AppColors.cyanAccent),
              title: const Text('Manage My Lights', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
              subtitle: const Text('Add, remove, or switch lights', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
              onTap: () {
                Navigator.pop(context);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (ctx) => const DeviceLibrarySheet(),
                );
              },
            ),
          ),
          const SizedBox(height: 14),

          // Sound (Buzzer) Toggle
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.glassBoxDecoration(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      widget.soundEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                      color: widget.soundEnabled ? AppColors.cyanAccent : AppColors.textMuted,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Hardware Audio Feedback',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          widget.soundEnabled ? 'Buzzer events enabled' : 'Buzzer silenced',
                          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ],
                ),
                Switch(
                  value: widget.soundEnabled,
                  onChanged: (val) {
                    HapticService.selectionTick();
                    widget.onToggleSound();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Sleep Timer
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.glassBoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.bedtime_outlined, color: AppColors.amberAccent),
                        SizedBox(width: 12),
                        Text(
                          'Automatic Sleep Timer',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${_timerSteps[_sliderIndex.toInt()]} mins',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.amberAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: AppColors.amberAccent,
                    inactiveTrackColor: AppColors.cardSurfaceSecondary,
                    thumbColor: Colors.white,
                    trackHeight: 6.0,
                  ),
                  child: Slider(
                    value: _sliderIndex,
                    min: 0,
                    max: (_timerSteps.length - 1).toDouble(),
                    divisions: _timerSteps.length - 1,
                    onChanged: (val) {
                      setState(() => _sliderIndex = val);
                    },
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _timerActive
                              ? AppColors.cardSurfaceSecondary
                              : AppColors.amberAccent,
                          foregroundColor: _timerActive ? AppColors.textPrimary : Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          HapticService.pop();
                          setState(() => _timerActive = true);
                          widget.onSetTimer(_timerSteps[_sliderIndex.toInt()]);
                        },
                        child: Text(
                          _timerActive ? 'Timer Running' : 'Start Timer',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    if (_timerActive) ...[
                      const SizedBox(width: 10),
                      IconButton(
                        onPressed: () {
                          HapticService.lightTick();
                          setState(() => _timerActive = false);
                          widget.onSetTimer(0);
                        },
                        icon: const Icon(Icons.close_rounded, color: AppColors.redAccent),
                      ),
                    ],
                  ],
                ),
                if (_timerActive && widget.timerRemainingSec != null) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      'Time remaining: ${widget.timerRemainingSec! ~/ 60}m ${widget.timerRemainingSec! % 60}s',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.amberAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Diagnostics Info & Reset
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.glassBoxDecoration(),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Firmware Protocol', style: TextStyle(color: AppColors.textMuted)),
                    Text(widget.firmwareVersion ?? 'Unknown Version', style: const TextStyle(color: AppColors.cyanAccent, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Architecture', style: TextStyle(color: AppColors.textMuted)),
                    Text('ESP32-C3 RISC-V', style: TextStyle(color: AppColors.textPrimary)),
                  ],
                ),
                const Divider(color: AppColors.cardBorder, height: 24),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.redAccent,
                      side: BorderSide(color: AppColors.redAccent.withOpacity(0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _showFactoryResetDialog(context),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Factory Reset Hardware'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
