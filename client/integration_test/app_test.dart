import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:microlab/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches and renders initial screen', (tester) async {
    app.main();
    // Allow Firebase init + splash animation to start
    await tester.pump(const Duration(seconds: 1));

    // App built → MaterialApp must be in the tree
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('splash screen is visible on launch', (tester) async {
    app.main();
    await tester.pump(const Duration(milliseconds: 500));

    // The splash renders a Scaffold; verify the app started rendering
    expect(find.byType(Scaffold), findsWidgets);
  });
}
