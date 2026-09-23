import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/devices/device_catalog.dart';
import '../../../core/ble/ble_transport.dart';
import '../../../core/devices/paired_device.dart';
import '../../connection/application/connection_notifier.dart';
import '../application/device_library_notifier.dart';
import 'add_device_flow.dart';
import 'device_type_picker.dart';

class DeviceLibrarySheet extends ConsumerWidget {
  const DeviceLibrarySheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryState = ref.watch(deviceLibraryProvider);
    final connState = ref.watch(connectionProvider);

    return Container(
      decoration: AppTheme.glassBoxDecoration(),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'My Lights',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (libraryState.devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  'No lights added yet.',
                  style: TextStyle(color: Colors.white54, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: libraryState.devices.length,
                  itemBuilder: (context, index) {
                    final device = libraryState.devices[index];
                    final profile = DeviceCatalog.getById(device.profileId);
                    final isActive = device.id == libraryState.activeDeviceId;
                    final isConnected = isActive && connState.state == DeviceConnectionState.connected;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor: isActive ? AppColors.cyanAccent.withOpacity(0.2) : Colors.white10,
                        child: Icon(
                          profile.icon,
                          color: isActive ? AppColors.cyanAccent : Colors.white54,
                        ),
                      ),
                      title: Text(
                        device.label,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        profile.displayName,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isActive)
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isConnected ? Colors.greenAccent : Colors.white24,
                              ),
                            ),
                          const SizedBox(width: 8),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, color: Colors.white54),
                            color: AppColors.cardSurfaceSecondary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            elevation: 8,
                            itemBuilder: (context) => [
                              if (isConnected)
                                const PopupMenuItem(
                                  value: 'disconnect',
                                  child: Row(
                                    children: [
                                      Icon(Icons.power_settings_new_rounded, color: AppColors.amberAccent, size: 20),
                                      SizedBox(width: 12),
                                      Text('Disconnect', style: TextStyle(color: Colors.white)),
                                    ],
                                  ),
                                )
                              else
                                const PopupMenuItem(
                                  value: 'connect',
                                  child: Row(
                                    children: [
                                      Icon(Icons.power_rounded, color: AppColors.greenAccent, size: 20),
                                      SizedBox(width: 12),
                                      Text('Connect', style: TextStyle(color: Colors.white)),
                                    ],
                                  ),
                                ),
                              const PopupMenuItem(
                                value: 'rename',
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_rounded, color: Colors.white, size: 20),
                                    SizedBox(width: 12),
                                    Text('Rename', style: TextStyle(color: Colors.white)),
                                  ],
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'retype',
                                child: Row(
                                  children: [
                                    Icon(Icons.category_rounded, color: Colors.white, size: 20),
                                    SizedBox(width: 12),
                                    Text('Change Type', style: TextStyle(color: Colors.white)),
                                  ],
                                ),
                              ),
                              const PopupMenuDivider(),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_forever_rounded, color: AppColors.redAccent, size: 20),
                                    SizedBox(width: 12),
                                    Text('Remove', style: TextStyle(color: AppColors.redAccent)),
                                  ],
                                ),
                              ),
                            ],
                            onSelected: (val) => _handleMenuAction(context, ref, val, device),
                          ),
                        ],
                      ),
                      onTap: () async {
                        if (!isConnected) {
                          await _handleConnect(context, ref, device);
                        } else {
                          if (context.mounted) {
                            Navigator.pop(context);
                          }
                        }
                      },
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (context) => const AddDeviceFlow(),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.cyanAccent.withOpacity(0.2),
                  foregroundColor: AppColors.cyanAccent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add a Light', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _handleMenuAction(BuildContext context, WidgetRef ref, String action, PairedDevice device) {
    if (action == 'connect') {
      _handleConnect(context, ref, device);
    } else if (action == 'disconnect') {
      ref.read(connectionProvider.notifier).disconnect();
      Navigator.pop(context);
    } else if (action == 'rename') {
      _showRenameDialog(context, ref, device);
    } else if (action == 'retype') {
      Navigator.pop(context);
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (context) => DeviceTypePicker(
          onSelected: (profileId) {
            ref.read(deviceLibraryProvider.notifier).retypeDevice(device.id, profileId);
            Navigator.pop(context);
          },
        ),
      );
    } else if (action == 'remove') {
      _showRemoveDialog(context, ref, device);
    }
  }

  Future<void> _handleConnect(BuildContext context, WidgetRef ref, PairedDevice device) async {
    await ref.read(connectionProvider.notifier).disconnect();
    await ref.read(deviceLibraryProvider.notifier).setActiveDevice(device.id);
    final ok = await ref.read(connectionProvider.notifier).connect(
      DiscoveredDevice(id: device.id, name: device.label, rssi: -50),
    );
    if (ok) {
      await ref.read(deviceLibraryProvider.notifier).touchLastConnected(device.id);
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not reach "${device.label}". Try scanning nearby.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
    if (context.mounted) {
      Navigator.pop(context);
    }
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref, PairedDevice device) {
    final controller = TextEditingController(text: device.label);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardSurfaceSecondary,
        title: const Text('Rename Light', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.cyanAccent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              ref.read(deviceLibraryProvider.notifier).renameDevice(device.id, controller.text);
              Navigator.pop(context);
            },
            child: const Text('Save', style: TextStyle(color: AppColors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  void _showRemoveDialog(BuildContext context, WidgetRef ref, PairedDevice device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardSurfaceSecondary,
        title: const Text('Remove Light?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to remove "${device.label}"? This will delete its saved presets from your device.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final activeId = ref.read(deviceLibraryProvider).activeDeviceId;
              if (activeId == device.id) {
                ref.read(connectionProvider.notifier).disconnect();
              }
              final profile = DeviceCatalog.getById(device.profileId);
              ref.read(deviceLibraryProvider.notifier).removeDevice(device.id, profile.numPresets);
              Navigator.pop(context);
            },
            child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
