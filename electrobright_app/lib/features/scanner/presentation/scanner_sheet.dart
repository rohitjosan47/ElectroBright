import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../../../core/ble/ble_transport.dart';
import '../../connection/application/connection_notifier.dart';

class ScannerSheet extends ConsumerStatefulWidget {
  final Set<String>? excludeIds;
  final void Function(String id, String name)? onDeviceSelected;

  const ScannerSheet({
    super.key,
    this.excludeIds,
    this.onDeviceSelected,
  });

  @override
  ConsumerState<ScannerSheet> createState() => _ScannerSheetState();
}

class _ScannerSheetState extends ConsumerState<ScannerSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(connectionProvider.notifier).startScan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final liveConn = ref.watch(connectionProvider);
    final connectionState = liveConn.state;
    
    var discoveredDevices = liveConn.discoveredDevices;
    if (widget.excludeIds != null) {
      discoveredDevices = discoveredDevices.where((d) => !widget.excludeIds!.contains(d.id)).toList();
    }

    final isScanning = connectionState == DeviceConnectionState.scanning;

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Bluetooth Devices',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              TextButton.icon(
                onPressed: isScanning ? null : () => ref.read(connectionProvider.notifier).startScan(),
                icon: isScanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyanAccent),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18, color: AppColors.cyanAccent),
                label: Text(
                  isScanning ? 'Scanning...' : 'Scan',
                  style: const TextStyle(color: AppColors.cyanAccent, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (discoveredDevices.isEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(32),
              decoration: AppTheme.glassBoxDecoration(),
              child: Column(
                children: [
                  Icon(
                    isScanning ? Icons.radar_rounded : Icons.bluetooth_searching_rounded,
                    size: 40,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isScanning ? 'Searching for ElectroBright_BLE...' : 'No fixtures detected yet',
                    style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Ensure fixture is powered and in advertising range',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ] else ...[
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: discoveredDevices.length,
              separatorBuilder: (ctx, i) => const SizedBox(height: 10),
              itemBuilder: (ctx, index) {
                final d = discoveredDevices[index];
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: AppTheme.glassBoxDecoration(),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.cyanAccent.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.lightbulb_outline_rounded, color: AppColors.cyanAccent, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                d.name,
                                style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                              ),
                              Text(
                                '${d.rssi} dBm',
                                style: const TextStyle(fontSize: 12, color: AppColors.cyanAccent),
                              ),
                            ],
                          ),
                        ],
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.cyanAccent,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          HapticService.pop();
                          if (widget.onDeviceSelected != null) {
                            widget.onDeviceSelected!(d.id, d.name);
                          } else {
                            ref.read(connectionProvider.notifier).connect(d);
                            Navigator.of(context).pop();
                          }
                        },
                        child: const Text('Connect', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
