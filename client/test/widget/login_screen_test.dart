// Widget tests for screens/shared/login_screen.dart — role selection and
// mobile-number validation.
//
// Deliberately never taps "Send OTP": that button's onPressed calls
// ApiService.sendOtp, which does a raw, non-injected `http.post` straight to
// AppConstants.serverUrl (a real, hardcoded host — see
// client/lib/constants/app_constants.dart). LoginScreen/ApiService have no
// dependency-injected HTTP client to intercept in a test, so tapping it here
// would either hang waiting on a real network call or actually hit a real
// server with test data — exactly what this task's safety rules forbid.
// This is a real testability gap in the app, reported in the final test
// report; it does not block testing the screen's own validation logic below,
// which runs entirely client-side before that button is ever enabled.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/screens/shared/login_screen.dart';

void main() {
  Widget wrap() => const MaterialApp(home: Scaffold(body: LoginScreen()));

  group('LoginScreen — role selection', () {
    testWidgets('defaults to Customer role', (tester) async {
      await tester.pumpWidget(wrap());
      expect(find.text('Enter mobile number'), findsOneWidget);
      expect(find.text('Technician login'), findsNothing);
    });

    // TC-LOGIN-01 — tapping the Technician card switches the active role,
    // reflected in both the screen title and subtitle copy.
    testWidgets('tapping Technician switches the active role', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Technician'));
      await tester.pump();

      expect(find.text('Technician login'), findsOneWidget);
      expect(find.text('Enter your registered technician mobile number'), findsOneWidget);
    });

    testWidgets('tapping back to Customer restores the customer copy', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Technician'));
      await tester.pump();
      await tester.tap(find.text('Customer'));
      await tester.pump();

      expect(find.text('Enter mobile number'), findsOneWidget);
    });
  });

  group('LoginScreen — mobile number validation', () {
    // TC-LOGIN-02 — the Send OTP button starts disabled (empty field) and
    // only enables once a real 10-digit, 6-9-leading Indian mobile number is
    // entered — the same regex the backend's own send-otp validation uses,
    // duplicated client-side to fail fast without a round trip.
    testWidgets('Send OTP is disabled until a valid mobile number is entered', (tester) async {
      await tester.pumpWidget(wrap());
      final sendOtpButton = find.widgetWithText(ElevatedButton, 'Send OTP');
      expect(tester.widget<ElevatedButton>(sendOtpButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.pump();

      expect(tester.widget<ElevatedButton>(sendOtpButton).onPressed, isNotNull);
    });

    // TC-LOGIN-03 — negative case: a number starting with a disallowed
    // digit (0-5) is never valid, no matter the length, and shows the
    // client-side validation message instead of silently doing nothing.
    testWidgets('a number starting with an invalid leading digit shows an error', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byType(TextField), '1234567890');
      await tester.pump();

      expect(find.text('Enter a valid 10-digit mobile number'), findsOneWidget);
      final sendOtpButton = find.widgetWithText(ElevatedButton, 'Send OTP');
      expect(tester.widget<ElevatedButton>(sendOtpButton).onPressed, isNull);
    });

    // Negative case: a valid-looking prefix that's still too short must not
    // be treated as valid — the button stays disabled mid-entry.
    testWidgets('a too-short number keeps Send OTP disabled', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byType(TextField), '98765');
      await tester.pump();

      final sendOtpButton = find.widgetWithText(ElevatedButton, 'Send OTP');
      expect(tester.widget<ElevatedButton>(sendOtpButton).onPressed, isNull);
    });

    testWidgets('the input is capped at 10 digits and non-digit characters are stripped', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byType(TextField), '98a76543210999');
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text.length, lessThanOrEqualTo(10));
      expect(field.controller!.text, matches(RegExp(r'^\d*$')));
    });
  });
}
