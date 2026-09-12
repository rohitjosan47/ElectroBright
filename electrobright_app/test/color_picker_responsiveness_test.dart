import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:electrobright_app/core/widgets/color_picker/hue_ring_inner_square_wheel.dart';
import 'package:electrobright_app/core/widgets/color_picker/interactive_color_square.dart';
import 'package:electrobright_app/features/dashboard/presentation/widgets/rgbw_palette_card.dart';
import 'package:electrobright_app/features/dashboard/presentation/widgets/police_dual_picker.dart';

void main() {
  group('Color Picker Responsiveness & Drag Interaction Tests', () {
    testWidgets('RgbwPaletteCard supports Wheel with inner square and Sliders', (tester) async {
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

      // Verify header and tab buttons (Only 2 tabs: Wheel & Sliders)
      expect(find.text('Color Palette'), findsOneWidget);
      expect(find.text('Wheel'), findsOneWidget); // Active tab displays text
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
      // Square tab should NO LONGER exist as a separate tab button
      expect(find.byIcon(Icons.crop_square_rounded), findsNothing);

      // Initial tab renders HueRingInnerSquareWheel
      expect(find.byType(HueRingInnerSquareWheel), findsOneWidget);

      final wheelFinder = find.byType(HueRingInnerSquareWheel);
      final center = tester.getCenter(wheelFinder);

      // 1. Drag the inner square (center)
      final squareGesture = await tester.startGesture(center);
      expect(isInteracting, isTrue);

      await squareGesture.moveBy(const Offset(20, -15));
      await tester.pump();
      expect(lastContinuous, isTrue);

      await squareGesture.up();
      await tester.pump();
      expect(isInteracting, isFalse);
      expect(lastContinuous, isFalse);

      // 2. Drag the outer hue ring (radius ~ 110px from center)
      final ringStart = center + const Offset(105, 0);
      final ringGesture = await tester.startGesture(ringStart);
      expect(isInteracting, isTrue);

      await ringGesture.moveBy(const Offset(-30, 80));
      await tester.pump();
      expect(lastContinuous, isTrue);

      await ringGesture.up();
      await tester.pump();
      expect(isInteracting, isFalse);
      expect(lastContinuous, isFalse);
      expect(lastR >= 0 && lastG >= 0 && lastB >= 0 && lastW >= 0, isTrue);

      // 3. Switch to Sliders tab by tapping sliders icon
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Sliders'), findsOneWidget);
      expect(find.text('Red Channel'), findsOneWidget);
      expect(find.text('Green Channel'), findsOneWidget);
      expect(find.text('Blue Channel'), findsOneWidget);
      expect(find.text('True White Channel'), findsOneWidget);
    });

    testWidgets('PoliceDualPicker renders InteractiveColorSquare in dialog without glitches', (tester) async {
      Color pickedA = Colors.red;
      Color pickedB = Colors.blue;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceDualPicker(
                colorA: pickedA,
                colorB: pickedB,
                onColorAChanged: (r, g, b, w) {
                  pickedA = Color.fromARGB(255, r, g, b);
                },
                onColorBChanged: (r, g, b, w) {
                  pickedB = Color.fromARGB(255, r, g, b);
                },
              ),
            ),
          ),
        ),
      );

      // Verify Police Dual Picker renders beacon cards
      expect(find.text('Beacon A'), findsWidgets);
      expect(find.text('Beacon B'), findsWidgets);

      // Tap Beacon A swatch card to open dialog
      await tester.tap(find.text('Beacon A').last);
      await tester.pump(const Duration(milliseconds: 300));

      // Verify dialog is open and contains InteractiveColorSquare
      expect(find.byType(InteractiveColorSquare), findsOneWidget);
      expect(find.text('Set Police Beacon A'), findsOneWidget);

      // Drag inside InteractiveColorSquare
      final squareFinder = find.byType(InteractiveColorSquare);
      final gesture = await tester.startGesture(tester.getCenter(squareFinder));
      await gesture.moveBy(const Offset(30, -20));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // Tap Apply Color button
      await tester.tap(find.text('Apply Color'));
      await tester.pump(const Duration(milliseconds: 300));

      // Dialog closed
      expect(find.byType(InteractiveColorSquare), findsNothing);
    });
  });
}
