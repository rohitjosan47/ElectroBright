import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../domain/mode_definition.dart';

class ModeCarousel extends StatefulWidget {
  final List<ModeDefinition> modes;
  final int activeModeId;
  final ValueChanged<int> onModeSelected;

  const ModeCarousel({
    super.key,
    required this.modes,
    required this.activeModeId,
    required this.onModeSelected,
  });

  @override
  State<ModeCarousel> createState() => _ModeCarouselState();
}

class _ModeCarouselState extends State<ModeCarousel> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    // Scroll to active mode on initial load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActiveMode(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant ModeCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeModeId != widget.activeModeId) {
      _scrollToActiveMode(animate: true);
    }
  }

  void _scrollToActiveMode({required bool animate}) {
    if (!_scrollController.hasClients) return;

    final index = widget.modes.indexWhere((m) => m.id == widget.activeModeId);
    if (index == -1) return;

    // Card width (140) + separator (14) = 154.0
    const cardWidth = 154.0;
    final screenWidth = MediaQuery.of(context).size.width;
    final targetOffset = (index * cardWidth) - (screenWidth / 2) + (140 / 2) + 20;

    final clampedOffset = targetOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if (animate) {
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clampedOffset);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Lighting Effects',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.cardSurfaceSecondary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Mode ${widget.activeModeId} / 13',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.cyanAccent,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 140,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: widget.modes.length,
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            itemBuilder: (context, index) {
              final mode = widget.modes[index];
              final isSelected = mode.id == widget.activeModeId;

              return GestureDetector(
                onTap: () {
                  HapticService.selectionTick();
                  widget.onModeSelected(mode.id);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  width: 140,
                  padding: const EdgeInsets.all(14.0),
                  decoration: AppTheme.glassBoxDecoration(
                    color: isSelected
                        ? AppColors.cardSurfaceSecondary
                        : AppColors.cardSurface.withOpacity(0.6),
                    borderColor: isSelected
                        ? AppColors.cyanAccent
                        : AppColors.cardBorder.withOpacity(0.5),
                    borderRadius: 20.0,
                    glow: isSelected,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Mode Icon with Gradient Glow
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: mode.accentGradient,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: mode.accentGradient.colors.first.withOpacity(0.5),
                                    blurRadius: 10,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          mode.icon,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mode.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                              color: isSelected ? Colors.white : AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            mode.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
