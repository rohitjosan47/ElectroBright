import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../../../core/widgets/color_picker/hue_ring_inner_square_wheel.dart';

class RgbwPaletteCard extends StatefulWidget {
  final int red;
  final int green;
  final int blue;
  final int white;
  final ValueChanged<bool>? onInteractionChanged;
  final Function(int r, int g, int b, int w, bool continuous) onRgbwChanged;

  const RgbwPaletteCard({
    super.key,
    required this.red,
    required this.green,
    required this.blue,
    required this.white,
    this.onInteractionChanged,
    required this.onRgbwChanged,
  });

  @override
  State<RgbwPaletteCard> createState() => _RgbwPaletteCardState();
}

class _RgbwPaletteCardState extends State<RgbwPaletteCard> {
  int _selectedTab = 0; // 0 = Wheel (Ring + Inner Square), 1 = Sliders (RGBW)
  late int _r;
  late int _g;
  late int _b;
  late int _w;
  bool _isInteracting = false;

  @override
  void initState() {
    super.initState();
    _r = widget.red;
    _g = widget.green;
    _b = widget.blue;
    _w = widget.white;
  }

  @override
  void didUpdateWidget(covariant RgbwPaletteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isInteracting) {
      if (oldWidget.red != widget.red ||
          oldWidget.green != widget.green ||
          oldWidget.blue != widget.blue ||
          oldWidget.white != widget.white) {
        if (widget.red != _r || widget.green != _g || widget.blue != _b || widget.white != _w) {
          setState(() {
            _r = widget.red;
            _g = widget.green;
            _b = widget.blue;
            _w = widget.white;
          });
        }
      }
    }
  }

  @override
  void dispose() {
    widget.onInteractionChanged?.call(false);
    super.dispose();
  }

  Color get _currentColor => Color.fromARGB(255, _r, _g, _b);

  void _onInternalInteractionChanged(bool interacting) {
    _isInteracting = interacting;
    widget.onInteractionChanged?.call(interacting);
  }

  @override
  Widget build(BuildContext context) {
    final hexCode = '#${_r.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${_g.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${_b.toRadixString(16).padLeft(2, '0').toUpperCase()}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.all(20.0),
        decoration: AppTheme.glassBoxDecoration(
          glow: true,
          borderColor: _currentColor.withOpacity(0.4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header & Tab Switcher
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    // Live Color Indicator Swatch
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _currentColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: _currentColor.withOpacity(0.6),
                            blurRadius: 10,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Color Palette',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '$hexCode  •  W: $_w',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                // 2-Way Tab Switcher Pill: Wheel | Sliders
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppColors.cardSurfaceSecondary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      _buildTabButton(0, Icons.donut_large_rounded, 'Wheel'),
                      _buildTabButton(1, Icons.tune_rounded, 'Sliders'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Tab View: 0 = Wheel (Hue Ring + Inner Square), 1 = Sliders (RGBW)
            if (_selectedTab == 0) ...[
              Center(
                child: HueRingInnerSquareWheel(
                  red: _r,
                  green: _g,
                  blue: _b,
                  white: _w,
                  onInteractionChanged: _onInternalInteractionChanged,
                  onRgbwChanged: (r, g, b, w, continuous) {
                    setState(() {
                      _r = r;
                      _g = g;
                      _b = b;
                      _w = w;
                    });
                    widget.onRgbwChanged(r, g, b, w, continuous);
                  },
                ),
              ),
            ] else ...[
              // Individual 4-Channel Sliders (RGBW)
              _buildChannelSlider(
                label: 'Red Channel',
                value: _r,
                activeColor: AppColors.channelRed,
                onChanged: (val) {
                  setState(() => _r = val);
                  widget.onRgbwChanged(_r, _g, _b, _w, true);
                },
                onChangeEnd: (val) => widget.onRgbwChanged(_r, _g, _b, _w, false),
              ),
              _buildChannelSlider(
                label: 'Green Channel',
                value: _g,
                activeColor: AppColors.channelGreen,
                onChanged: (val) {
                  setState(() => _g = val);
                  widget.onRgbwChanged(_r, _g, _b, _w, true);
                },
                onChangeEnd: (val) => widget.onRgbwChanged(_r, _g, _b, _w, false),
              ),
              _buildChannelSlider(
                label: 'Blue Channel',
                value: _b,
                activeColor: AppColors.channelBlue,
                onChanged: (val) {
                  setState(() => _b = val);
                  widget.onRgbwChanged(_r, _g, _b, _w, true);
                },
                onChangeEnd: (val) => widget.onRgbwChanged(_r, _g, _b, _w, false),
              ),
              _buildChannelSlider(
                label: 'True White Channel',
                value: _w,
                activeColor: AppColors.channelWhite,
                onChanged: (val) {
                  setState(() => _w = val);
                  widget.onRgbwChanged(_r, _g, _b, _w, true);
                },
                onChangeEnd: (val) => widget.onRgbwChanged(_r, _g, _b, _w, false),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(int index, IconData icon, String label) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () {
        HapticService.selectionTick();
        setState(() => _selectedTab = index);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.cyanAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.black : AppColors.textMuted,
            ),
            if (isSelected) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChannelSlider({
    required String label,
    required int value,
    required Color activeColor,
    required ValueChanged<int> onChanged,
    required ValueChanged<int> onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: activeColor.withOpacity(0.9),
                ),
              ),
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: activeColor,
              inactiveTrackColor: AppColors.cardSurfaceSecondary,
              thumbColor: Colors.white,
              overlayColor: activeColor.withOpacity(0.2),
              trackHeight: 6.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9.0),
            ),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 255,
              onChangeStart: (_) => _onInternalInteractionChanged(true),
              onChanged: (val) {
                onChanged(val.round());
              },
              onChangeEnd: (val) {
                _onInternalInteractionChanged(false);
                onChangeEnd(val.round());
              },
            ),
          ),
        ],
      ),
    );
  }
}
