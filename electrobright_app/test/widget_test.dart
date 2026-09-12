import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:electrobright_app/app.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';

void main() {
  testWidgets('ElectroBright App boots into Dashboard with all cards', (WidgetTester tester) async {
    // Set a realistic mobile viewport height so all cards can render
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final mockTransport = MockBleTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleTransportProvider.overrideWithValue(mockTransport),
        ],
        child: const ElectroBrightApp(),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Master Brightness section exists
    expect(find.text('Master Brightness'), findsOneWidget);

    // Verify Color Palette section exists
    expect(find.text('Color Palette'), findsOneWidget);

    // Verify Lighting Effects carousel exists
    expect(find.text('Lighting Effects'), findsOneWidget);

    // Verify Preset Vault exists
    expect(find.text('Preset Memory Vault'), findsOneWidget);
  });
}
