import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/devices/device_catalog.dart';

class DeviceTypePicker extends StatelessWidget {
  final ValueChanged<String> onSelected;

  const DeviceTypePicker({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
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
                'Select Light Type',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: DeviceCatalog.allProfiles.length,
                itemBuilder: (context, index) {
                  final profile = DeviceCatalog.allProfiles[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: Colors.white10,
                      child: Icon(profile.icon, color: Colors.white),
                    ),
                    title: Text(
                      profile.displayName,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${profile.numModes} modes, ${profile.numPresets} presets',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    onTap: () => onSelected(profile.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
