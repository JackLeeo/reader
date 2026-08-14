// 基本 smoke test
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Smoke test renders widget tree', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('换源阅读')),
        ),
      ),
    );
    expect(find.text('换源阅读'), findsOneWidget);
  });
}
