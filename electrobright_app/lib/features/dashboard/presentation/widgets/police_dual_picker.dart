import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../../../core/widgets/color_picker/interactive_color_square.dart';

class PoliceDualPicker extends StatefulWidget {
  final Color colorA;
  final Color colorB;
  final Function(int r, int g, int b, int w) onColorAChanged;
  final Function(int r, int g, int b, int w) onColorBChanged;

  const PoliceDualPicker({
    super.key,
    required this.colorA,
    required this.colorB,
    required this.onColorAChanged,
    required this.onColorBChanged,
  });

  @override
  State<PoliceDualPicker> createState() => _PoliceDualPickerState();
}

class _PoliceDualPickerState extends State<PoliceDualPicker>
    with SingleTickerProviderStateMixin {
  late AnimationController _strobeAnimController;

  @override
  void initState() {
    super.initState();
    // Simulate live wig-wag strobe preview
    _strobeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _strobeAnimController.dispose();
    super.dispose();
  }

  void _showColorDialog(
      BuildContext context, String title, Color initialColor, Function(Color) onPicked) {
    Color selected = initialColor;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.cardSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: selected,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: selected.withOpacity(0.6),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: 300,
              child: InteractiveColorSquare(
                initialColor: selected,
                onColorChanged: (c) {
                  selected = c;
                  setDialogState(() {});
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.cyanAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  onPicked(selected);
                  Navigator.of(ctx).pop();
                },
                child: const Text('Apply Color', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppColors.cardSurfaceSecondary.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Custom Strobe Beacons',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),

              // Live Alternating Strobe Simulator Dot
              AnimatedBuilder(
                animation: _strobeAnimController,
                builder: (context, child) {
                  final isA = _strobeAnimController.value < 0.5;
                  final currentStrobeColor = isA ? widget.colorA : widget.colorB;

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: currentStrobeColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: currentStrobeColor, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: currentStrobeColor,
                            boxShadow: [
                              BoxShadow(color: currentStrobeColor, blurRadius: 6),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isA ? 'Beacon A' : 'Beacon B',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: currentStrobeColor,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Side-by-Side Color Swatches
          Row(
            children: [
              Expanded(
                child: _buildSwatchCard(
                  title: 'Beacon A',
                  color: widget.colorA,
                  onTap: () {
                    HapticService.selectionTick();
                    _showColorDialog(context, 'Set Police Beacon A', widget.colorA, (picked) {
                      widget.onColorAChanged(picked.red, picked.green, picked.blue, 0);
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSwatchCard(
                  title: 'Beacon B',
                  color: widget.colorB,
                  onTap: () {
                    HapticService.selectionTick();
                    _showColorDialog(context, 'Set Police Beacon B', widget.colorB, (picked) {
                      widget.onColorBChanged(picked.red, picked.green, picked.blue, 0);
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSwatchCard({
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.5), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.6), blurRadius: 8),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Text(
                    'Tap to edit',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
