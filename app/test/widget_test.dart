import 'package:electrobright/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to the Lights screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ElectroBrightApp()));
    await tester.pumpAndSettle();
    expect(find.text('Lights'), findsOneWidget);
  });
}
