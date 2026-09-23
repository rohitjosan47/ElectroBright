import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/haptics/haptic_service.dart';
import '../../../../core/ble/ble_transport.dart';

class HeaderBar extends StatelessWidget {
  final DeviceConnectionState connectionState;
  final String? activeDeviceLabel;
  final bool isSleeping;
  final int reconnectAttempt;
  final int maxReconnectAttempts;
  final VoidCallback onConnectionTap;
  final VoidCallback onPowerTap;
  final VoidCallback onSettingsTap;

  const HeaderBar({
    super.key,
    required this.connectionState,
    this.activeDeviceLabel,
    required this.isSleeping,
    this.reconnectAttempt = 0,
    this.maxReconnectAttempts = 3,
    required this.onConnectionTap,
    required this.onPowerTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = connectionState == DeviceConnectionState.connected;
    final isReconnecting = connectionState == DeviceConnectionState.reconnecting;
    final statusColor = isConnected
        ? AppColors.greenAccent
        : (isReconnecting ? AppColors.cyanAccent : AppColors.amberAccent);

    String labelText;
    if (isConnected) {
      labelText = activeDeviceLabel ?? 'Connected';
    } else if (isReconnecting) {
      labelText = 'Reconnecting ($reconnectAttempt/$maxReconnectAttempts)...';
    } else if (connectionState == DeviceConnectionState.scanning) {
      labelText = 'Scanning...';
    } else if (connectionState == DeviceConnectionState.connecting) {
      labelText = 'Connecting...';
    } else {
      labelText = activeDeviceLabel == null ? 'Connect Fixture' : 'Connect $activeDeviceLabel';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Connection Pill
          GestureDetector(
            onTap: () {
              HapticService.selectionTick();
              onConnectionTap();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(24.0),
                border: Border.all(
                  color: isConnected
                      ? AppColors.greenAccent.withOpacity(0.3)
                      : (isReconnecting
                          ? AppColors.cyanAccent.withOpacity(0.3)
                          : AppColors.cardBorder),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: 20,
                      height: 20,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                      boxShadow: [
                        BoxShadow(
                          color: statusColor,
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    labelText,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Action Controls: Power + Settings
          Row(
            children: [
              // Power Button
              GestureDetector(
                onTap: () {
                  HapticService.pop();
                  onPowerTap();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.all(10.0),
                  decoration: BoxDecoration(
                    color: isSleeping
                        ? AppColors.redAccent.withOpacity(0.15)
                        : AppColors.cyanAccent.withOpacity(0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSleeping
                          ? AppColors.redAccent.withOpacity(0.6)
                          : AppColors.cyanAccent.withOpacity(0.6),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isSleeping
                            ? AppColors.redAccent.withOpacity(0.3)
                            : AppColors.cyanAccent.withOpacity(0.3),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.power_settings_new_rounded,
                    size: 20,
                    color: isSleeping ? AppColors.redAccent : AppColors.cyanAccent,
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Settings Gear
              GestureDetector(
                onTap: () {
                  HapticService.selectionTick();
                  onSettingsTap();
                },
                child: Container(
                  padding: const EdgeInsets.all(10.0),
                  decoration: AppTheme.glassBoxDecoration(
                    borderRadius: 24.0,
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    size: 20,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
