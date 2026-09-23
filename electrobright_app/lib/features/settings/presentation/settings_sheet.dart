import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../dashboard/application/device_notifier.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../../../core/devices/device_profile.dart';
import '../../devices/presentation/device_library_sheet.dart';

class SettingsSheet extends StatefulWidget {
  final bool soundEnabled;
  final bool timerActive;
  final int timerSecondsSet;
  final int? timerRemainingSec;
  final String? firmwareVersion;
  final int writeErrorCount;
  final DeviceProfile profile;
  final VoidCallback onToggleSound;
  final ValueChanged<int> onSetTimer;
  final VoidCallback onFactoryReset;

  const SettingsSheet({
    super.key,
    required this.soundEnabled,
    required this.timerActive,
    required this.timerSecondsSet,
    this.timerRemainingSec,
    this.firmwareVersion,
    required this.writeErrorCount,
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

  // Minimum auto-sleep is 30 s (APP-HWSET-02).
  static const List<int> _timerSteps = [
    30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 5400, 7200, 10800, 14400, 21600
  ];

  String _formatTimerStep(int seconds) {
    if (seconds < 60) return '$seconds secs';
    final mins = seconds ~/ 60;
    if (mins < 60) return '$mins mins';
    final hours = mins / 60.0;
    return '${hours == hours.toInt() ? hours.toInt() : hours.toStringAsFixed(1)} hours';
  }

  @override
  void initState() {
    super.initState();
    int initialSecs = widget.timerSecondsSet > 0 ? widget.timerSecondsSet : 30;
    int closestIndex = 0;
    for (int i = 0; i < _timerSteps.length; i++) {
      if (_timerSteps[i] >= initialSecs) {
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

          // Sound (Buzzer) Toggle — reads the live device state so it always
          // reflects what the hardware reported, not a copy from when the
          // sheet was opened.
          Consumer(builder: (context, ref, _) {
          final soundEnabled = ref.watch(deviceStateProvider.select((s) => s.soundEnabled));
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.glassBoxDecoration(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      soundEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                      color: soundEnabled ? AppColors.cyanAccent : AppColors.textMuted,
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
                          soundEnabled ? 'Buzzer events enabled' : 'Buzzer silenced',
                          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ],
                ),
                Switch(
                  value: soundEnabled,
                  onChanged: (val) {
                    HapticService.selectionTick();
                    if (val != soundEnabled) widget.onToggleSound();
                  },
                ),
              ],
            ),
          );
          }),
          const SizedBox(height: 14),

          // Sleep Timer
          Consumer(
            builder: (context, ref, child) {
              final isSleeping = ref.watch(deviceStateProvider.select((s) => s.isSleeping));
              final timerActive = ref.watch(deviceStateProvider.select((s) => s.timerActive));
              return AnimatedOpacity(
                duration: const Duration(milliseconds: 350),
                opacity: isSleeping ? 0.3 : 1.0,
                child: IgnorePointer(
                  ignoring: isSleeping,
                  child: Container(
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
                      _formatTimerStep(_timerSteps[_sliderIndex.toInt()]),
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
                          backgroundColor: timerActive
                              ? AppColors.cardSurfaceSecondary
                              : AppColors.amberAccent,
                          foregroundColor: timerActive ? AppColors.textPrimary : Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          HapticService.pop();
                          widget.onSetTimer(_timerSteps[_sliderIndex.toInt()]);
                        },
                        child: timerActive 
                            ? Consumer(
                                builder: (context, ref, child) {
                                  final remaining = ref.watch(deviceStateProvider.select((s) => s.timerRemainingSec));
                                  if (remaining == null) return const Text('Timer Running', style: TextStyle(fontWeight: FontWeight.w700));
                                  final h = remaining ~/ 3600;
                                  final m = (remaining % 3600) ~/ 60;
                                  final s = remaining % 60;
                                  final timeStr = h > 0 
                                      ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
                                      : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
                                  return Text(
                                    timeStr,
                                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                                  );
                                },
                              )
                            : const Text('Start Timer', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    if (timerActive) ...[
                      const SizedBox(width: 10),
                      IconButton(
                        onPressed: () {
                          HapticService.lightTick();
                          widget.onSetTimer(0);
                        },
                        icon: const Icon(Icons.close_rounded, color: AppColors.redAccent),
                      ),
                    ],
                  ],
                ),

                      ],
                    ),
                  ),
                ),
              );
            },
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
                    Consumer(
                      builder: (context, ref, child) {
                        final version = ref.watch(deviceStateProvider.select((s) => s.firmwareVersion));
                        return Text(version ?? 'Unknown Version', style: const TextStyle(color: AppColors.cyanAccent, fontWeight: FontWeight.w600));
                      },
                    ),
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
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Transport Drop Count', style: TextStyle(color: AppColors.textMuted)),
                    Text('${widget.writeErrorCount}', style: TextStyle(color: widget.writeErrorCount > 0 ? AppColors.redAccent : AppColors.textPrimary)),
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
