import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:electrobright_app/features/dashboard/presentation/widgets/rgbw_palette_card.dart';

void main() {
  group('Color Picker Responsiveness & Drag Interaction Tests', () {
    testWidgets('RgbwPaletteCard supports Wheel, Square, and Sliders with smooth dragging', (tester) async {
      int lastR = 0, lastG = 0, lastB = 0, lastW = 0;
      bool lastContinuous = false;
      bool? isInteracting;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RgbwPaletteCard(
                red: 255,
                green: 0,
                blue: 0,
                white: 50,
                onInteractionChanged: (interacting) {
                  isInteracting = interacting;
                },
                onRgbwChanged: (r, g, b, w, continuous) {
                  lastR = r;
                  lastG = g;
                  lastB = b;
                  lastW = w;
                  lastContinuous = continuous;
                },
              ),
            ),
          ),
        ),
      );

      // Verify header and tab icons are present
      expect(find.text('Color Palette'), findsOneWidget);
      expect(find.text('Wheel'), findsOneWidget); // Active tab displays its text
      expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      // Initial tab is Wheel (HueRingPicker)
      expect(find.byType(HueRingPicker), findsOneWidget);

      // Drag across the wheel
      final wheelFinder = find.byType(HueRingPicker);
      final gesture = await tester.startGesture(tester.getCenter(wheelFinder));
      expect(isInteracting, isTrue);

      // Move continuously in a circle / drag path
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      expect(lastContinuous, isTrue);

      await gesture.moveBy(const Offset(-10, 30));
      await tester.pump();

      await gesture.up();
      await tester.pump();
      expect(isInteracting, isFalse);
      expect(lastContinuous, isFalse);
      expect(lastR >= 0 && lastG >= 0 && lastB >= 0 && lastW >= 0, isTrue);

      // Switch to Square tab by tapping square icon
      await tester.tap(find.byIcon(Icons.crop_square_rounded));
      await tester.pumpAndSettle();

      // Verify ColorPicker square is rendered and tab text appears
      expect(find.text('Square'), findsOneWidget);
      expect(find.byType(ColorPicker), findsOneWidget);

      // Drag across the square palette
      final squareFinder = find.byType(ColorPicker);
      final squareGesture = await tester.startGesture(tester.getCenter(squareFinder));
      expect(isInteracting, isTrue);

      await squareGesture.moveBy(const Offset(30, -20));
      await tester.pump();

      await squareGesture.up();
      await tester.pump();
      expect(isInteracting, isFalse);

      // Switch to Sliders tab by tapping sliders icon
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Sliders'), findsOneWidget);
      expect(find.text('Red Channel'), findsOneWidget);
      expect(find.text('Green Channel'), findsOneWidget);
      expect(find.text('Blue Channel'), findsOneWidget);
      expect(find.text('True White Channel'), findsOneWidget);
    });
  });
}
