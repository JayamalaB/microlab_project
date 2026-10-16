// Real Flutter ↔ real backend integration test — IT-C001 (Customer Login),
// driven end-to-end through the ACTUAL app (main.dart), not a pumped
// widget in isolation. Requires a real running instance of
// server/tests/e2e-web/bootstrapTestServer.js, pointed at via
// --dart-define=MICROLAB_SERVER_URL=http://localhost:<port> (see
// client/lib/constants/app_constants.dart's serverUrl override, added for
// this test). Every HTTP call this test triggers is a genuine network
// request from the compiled Flutter web app to that real Node process —
// nothing about the app or its networking is mocked; only the backend's
// own database/SMS/Firebase are, exactly like every other e2e test in this
// project.
//
// Run with (server already listening on port 4001):
//   flutter test integration_test/login_flow_web_test.dart -d chrome \
//     --dart-define=MICROLAB_SERVER_URL=http://localhost:4001
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:microlab/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('customer enters a mobile number, receives an OTP, and verifies it against the real backend', (tester) async {
    app.main();
    // Splash screen navigates after a fixed 2.5s delay (see splash_screen.dart).
    await tester.pumpAndSettle(const Duration(seconds: 4));

    // Land on the onboarding/login panel — Customer role is selected by default.
    expect(find.text('Enter mobile number'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '9876543210');
    await tester.pumpAndSettle();

    final sendOtpButton = find.widgetWithText(ElevatedButton, 'Send OTP');
    expect(tester.widget<ElevatedButton>(sendOtpButton).onPressed, isNotNull);
    await tester.tap(sendOtpButton);
    // Real network round trip to the real backend — wait for it to land and
    // the app to navigate to the OTP screen.
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Proves the real POST /api/auth/send-otp call succeeded and the app
    // really navigated based on that real response.
    expect(find.text('Verify OTP'), findsOneWidget);

    final otpBoxes = find.byType(TextField);
    expect(otpBoxes, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      await tester.enterText(otpBoxes.at(i), '1');
      await tester.pump();
    }

    final verifyButton = find.widgetWithText(ElevatedButton, 'Verify OTP');
    expect(tester.widget<ElevatedButton>(verifyButton).onPressed, isNotNull);
    await tester.tap(verifyButton);
    // Real POST /api/auth/verify-otp round trip, then real navigation away
    // from the OTP screen on success.
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('Verify OTP'), findsNothing);
    expect(find.text('Invalid or expired OTP'), findsNothing);
  });
}
