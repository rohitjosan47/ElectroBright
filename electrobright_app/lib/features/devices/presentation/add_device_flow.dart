import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/devices/device_catalog.dart';
import '../../../core/ble/ble_transport.dart';
import '../../scanner/presentation/scanner_sheet.dart';
import '../application/device_library_notifier.dart';
import '../../connection/application/connection_notifier.dart';
import '../../dashboard/application/device_notifier.dart';
import '../application/device_identity_service.dart';
import '../../../core/devices/paired_device.dart';
import 'device_type_picker.dart';

class AddDeviceFlow extends ConsumerStatefulWidget {
  const AddDeviceFlow({super.key});

  @override
  ConsumerState<AddDeviceFlow> createState() => _AddDeviceFlowState();
}

class _AddDeviceFlowState extends ConsumerState<AddDeviceFlow> {
  int _step = 0; // 0 = Scan, 1 = Identifying, 2 = Naming
  String? _targetId;
  DeviceIdentityResult? _identityResult;
  final _nameController = TextEditingController();

  void _onDeviceSelected(String id, String name) async {
    setState(() {
      _targetId = id;
      _step = 1;
    });

    // Disconnect whatever we are currently connected to
    await ref.read(connectionProvider.notifier).disconnect();

    final success = await ref.read(connectionProvider.notifier).connect(
      DiscoveredDevice(id: id, name: name, rssi: -50)
    );
    if (!success || !mounted) {
      if (mounted) setState(() => _step = 0);
      return;
    }

    final transport = ref.read(bleTransportProvider);
    final result = await DeviceIdentityService.identify(transport, name);

    if (!mounted) return;

    setState(() {
      _identityResult = result;
      // Auto-disambiguate name
      final baseName = result.profile.displayName;
      int count = 1;
      for (final d in ref.read(deviceLibraryProvider).devices) {
        if (d.profileId == result.profile.id) count++;
      }
      _nameController.text = count > 1 ? '$baseName $count' : baseName;
      _step = 2;
    });
  }

  void _finish() {
    if (_targetId == null || _identityResult == null) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final device = PairedDevice(
      id: _targetId!,
      profileId: _identityResult!.profile.id,
      label: name,
      addedAt: DateTime.now(),
    );

    final library = ref.read(deviceLibraryProvider.notifier);
    library.addDevice(device).then((_) => library.touchLastConnected(device.id));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_step == 0) {
      final existingIds = ref.watch(deviceLibraryProvider).devices.map((d) => d.id).toSet();
      return ScannerSheet(
        excludeIds: existingIds,
        onDeviceSelected: _onDeviceSelected,
      );
    }

    return Container(
      decoration: AppTheme.glassBoxDecoration(),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _step == 1 ? 'Connecting...' : 'Name Your Light',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 24),
              if (_step == 1)
              const Padding(
                padding: EdgeInsets.all(32.0),
                child: Center(child: CircularProgressIndicator(color: AppColors.cyanAccent)),
              )
            else if (_step == 2 && _identityResult != null) ...[
              if (!_identityResult!.wasPositivelyIdentified)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Unrecognized model. Please select the correct type.',
                            style: TextStyle(color: Colors.orange, fontSize: 14),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            showModalBottomSheet(
                              context: context,
                              backgroundColor: Colors.transparent,
                              builder: (context) => DeviceTypePicker(
                                onSelected: (pid) {
                                  setState(() {
                                    _identityResult = DeviceIdentityResult(DeviceCatalog.getById(pid), true);
                                  });
                                  Navigator.pop(context);
                                },
                              ),
                            );
                          },
                          child: const Text('Change'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!_identityResult!.wasPositivelyIdentified) const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TextField(
                  controller: _nameController,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  decoration: InputDecoration(
                    labelText: 'Light Name',
                    labelStyle: const TextStyle(color: Colors.white54),
                    prefixIcon: Icon(_identityResult!.profile.icon, color: AppColors.cyanAccent),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _finish(),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                          ref.read(connectionProvider.notifier).disconnect();
                          Navigator.pop(context);
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white54, fontSize: 16)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _finish,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.cyanAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        child: const Text('Done', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}
