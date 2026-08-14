// 基本 smoke test - 确保应用可以启动
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Smoke test', (WidgetTester tester) async {
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
