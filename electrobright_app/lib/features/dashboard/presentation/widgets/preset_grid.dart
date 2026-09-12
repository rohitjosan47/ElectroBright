import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';

class PresetGrid extends StatelessWidget {
  final int numPresets;
  final Set<int> savedPresets;
  final Map<int, String> presetNames;
  final int? activePresetId;
  final ValueChanged<int> onLoadPreset;
  final ValueChanged<int> onSavePreset;
  final ValueChanged<int> onDeletePreset;
  final Function(int slotId, String newName) onRenamePreset;

  const PresetGrid({
    super.key,
    required this.numPresets,
    required this.savedPresets,
    required this.presetNames,
    this.activePresetId,
    required this.onLoadPreset,
    required this.onSavePreset,
    required this.onDeletePreset,
    required this.onRenamePreset,
  });

  void _showRenameDialog(BuildContext context, int slotId, String currentName) {
    final controller = TextEditingController(text: currentName);
    const suggestions = [
      'Cozy Warmth',
      'Party Strobe',
      'Cinema Night',
      'Reading Glow',
      'Cyberpunk',
      'Midnight Amber',
      'Emerald Breath',
      'Ocean Wave',
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.cardSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.edit_note_rounded, color: AppColors.cyanAccent),
                const SizedBox(width: 8),
                Text(
                  'Rename Preset ${slotId + 1}',
                  style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: 'e.g. Cozy Warmth',
                      hintStyle: const TextStyle(color: AppColors.textMuted),
                      filled: true,
                      fillColor: AppColors.cardSurfaceSecondary,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.cardBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.cyanAccent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Quick Suggestions:',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: suggestions.map((tag) {
                      return GestureDetector(
                        onTap: () {
                          HapticService.selectionTick();
                          controller.text = tag;
                          setDialogState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.cardSurfaceSecondary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.cardBorder),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(fontSize: 11, color: AppColors.cyanAccent),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                  HapticService.pop();
                  final newName = controller.text.trim();
                  if (newName.isNotEmpty) {
                    onRenamePreset(slotId, newName);
                  }
                  Navigator.of(ctx).pop();
                },
                child: const Text('Save Name', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showPresetOptions(BuildContext context, int slotId, bool isSaved) {
    HapticService.pop();
    final currentName = presetNames[slotId] ?? 'Preset ${slotId + 1}';

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Slot ${slotId + 1} • ${isSaved ? "Saved Scene" : "Empty Slot"}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                  IconButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _showRenameDialog(context, slotId, currentName);
                    },
                    icon: const Icon(Icons.edit_rounded, color: AppColors.cyanAccent),
                    tooltip: 'Rename Preset',
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Rename Action
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.cyanAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.edit_note_rounded, color: AppColors.cyanAccent),
                ),
                title: const Text(
                  'Rename Preset',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showRenameDialog(context, slotId, currentName);
                },
              ),

              // Save Action
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.greenAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.save_rounded, color: AppColors.greenAccent),
                ),
                title: Text(
                  isSaved ? 'Overwrite with Current Look' : 'Save Current Look',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onSavePreset(slotId);
                },
              ),

              // Delete Action
              if (isSaved)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.redAccent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete_outline_rounded, color: AppColors.redAccent),
                  ),
                  title: const Text(
                    'Clear Preset',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.redAccent,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onDeletePreset(slotId);
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
                const Row(
                  children: [
                    Icon(
                      Icons.bookmark_outline_rounded,
                      color: AppColors.cyanAccent,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Preset Memory Vault',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                if (numPresets > 0)
                  Text(
                    '${savedPresets.length} / $numPresets Saved',
                    style: const TextStyle(
                      color: AppColors.cyanAccent,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),

            // Active Preset Banner (if one is loaded)
            if (activePresetId != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.cyanAccent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cyanAccent.withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.play_circle_fill_rounded, color: AppColors.cyanAccent, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          'Active: ${presetNames[activePresetId!] ?? 'Preset ${activePresetId! + 1}'}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      'Slot ${activePresetId! + 1}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.cyanAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 5x3 Grid
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 1.2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: numPresets,
              itemBuilder: (context, index) {
                final isSaved = savedPresets.contains(index);
                final isActive = activePresetId == index;
                final customName = presetNames[index] ?? 'P${index + 1}';

                return GestureDetector(
                  onTap: () {
                    if (isSaved) {
                      HapticService.pop();
                      onLoadPreset(index);
                    } else {
                      _showPresetOptions(context, index, isSaved);
                    }
                  },
                  onLongPress: () {
                    _showPresetOptions(context, index, isSaved);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.cyanAccent.withOpacity(0.15)
                          : (isSaved
                              ? AppColors.cardSurfaceSecondary
                              : AppColors.cardSurface.withOpacity(0.4)),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isActive
                            ? AppColors.cyanAccent
                            : (isSaved
                                ? AppColors.cyanAccent.withOpacity(0.5)
                                : AppColors.cardBorder),
                        width: isActive ? 2.0 : 1.0,
                      ),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: AppColors.cyanAccent.withOpacity(0.4),
                                blurRadius: 8,
                                spreadRadius: 1,
                              )
                            ]
                          : (isSaved
                              ? [
                                  BoxShadow(
                                    color: AppColors.cyanAccent.withOpacity(0.15),
                                    blurRadius: 4,
                                  )
                                ]
                              : null),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'P${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: isActive
                                ? AppColors.cyanAccent
                                : (isSaved ? Colors.white : AppColors.textMuted),
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (isSaved) ...[
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isActive ? AppColors.cyanAccent : AppColors.greenAccent,
                              boxShadow: [
                                BoxShadow(
                                  color: isActive ? AppColors.cyanAccent : AppColors.greenAccent,
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            customName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                              color: isActive ? AppColors.cyanAccent : AppColors.textMuted,
                            ),
                          ),
                        ] else ...[
                          const Icon(
                            Icons.add_rounded,
                            size: 16,
                            color: AppColors.textMuted,
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            const Center(
              child: Text(
                'Tap saved slot to recall • Long-press to rename, save or delete',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
