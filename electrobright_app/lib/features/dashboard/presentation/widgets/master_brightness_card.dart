import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/haptics/haptic_service.dart';

class MasterBrightnessCard extends StatefulWidget {
  final int brightness;
  final ValueChanged<bool>? onInteractionChanged;
  final Function(int value, bool continuous) onBrightnessChanged;

  const MasterBrightnessCard({
    super.key,
    required this.brightness,
    this.onInteractionChanged,
    required this.onBrightnessChanged,
  });

  @override
  State<MasterBrightnessCard> createState() => _MasterBrightnessCardState();
}

class _MasterBrightnessCardState extends State<MasterBrightnessCard> {
  late double _currentValue;
  int _lastTickStep = -1;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.brightness.toDouble();
  }

  @override
  void didUpdateWidget(covariant MasterBrightnessCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.brightness != widget.brightness) {
      setState(() {
        _currentValue = widget.brightness.toDouble();
      });
    }
  }

  @override
  void dispose() {
    widget.onInteractionChanged?.call(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final percent = ((_currentValue / 255) * 100).round();
    final glowFactor = (_currentValue / 255.0).clamp(0.0, 1.0);
    final borderColor = Color.lerp(
      AppColors.cardBorder,
      AppColors.amberAccent.withOpacity(0.55),
      glowFactor,
    )!;
    final shadowColor = AppColors.amberAccent.withOpacity(glowFactor * 0.35);
    final shadowBlur = 8.0 + (glowFactor * 14.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(20.0),
        decoration: BoxDecoration(
          color: AppColors.cardSurface.withOpacity(0.85),
          borderRadius: BorderRadius.circular(18.0),
          border: Border.all(
            color: borderColor,
            width: 1.2 + (glowFactor * 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 12.0,
              offset: const Offset(0, 4),
            ),
            if (glowFactor > 0.05)
              BoxShadow(
                color: shadowColor,
                blurRadius: shadowBlur,
                spreadRadius: glowFactor * 1.5,
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      percent == 0 ? Icons.brightness_3 : Icons.wb_sunny_rounded,
                      color: AppColors.amberAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Master Brightness',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.cardSurfaceSecondary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$percent%',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.amberAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.amberAccent,
                inactiveTrackColor: AppColors.cardSurfaceSecondary,
                thumbColor: Colors.white,
                overlayColor: AppColors.amberAccent.withOpacity(0.2),
                trackHeight: 8.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0),
              ),
              child: Slider(
                value: _currentValue,
                min: 0,
                max: 255,
                onChangeStart: (_) => widget.onInteractionChanged?.call(true),
                onChanged: (val) {
                  setState(() => _currentValue = val);
                  final step = (val / 25.5).floor();
                  if (step != _lastTickStep) {
                    _lastTickStep = step;
                    HapticService.lightTick();
                  }
                  widget.onBrightnessChanged(val.round(), true);
                },
                onChangeEnd: (val) {
                  widget.onInteractionChanged?.call(false);
                  widget.onBrightnessChanged(val.round(), false);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
