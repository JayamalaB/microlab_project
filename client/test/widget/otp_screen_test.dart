// Widget tests for screens/shared/otp_screen.dart — 4-digit entry, the dev
// OTP autofill banner, and the resend countdown.
//
// Never taps "Verify OTP" or "Resend OTP": both call AuthService methods
// that hit the real, non-injected, hardcoded backend host (see
// login_screen_test.dart's header comment for the full explanation — same
// gap, same reasoning). This file is pumped with a `devOtp` value, which the
// real LoginScreen → OtpScreen navigation never actually supplies (confirmed
// by reading login_screen.dart's Navigator.push call) — so the dev-OTP
// banner tested here is real, reachable code, but only reachable in
// isolation like this, not via the app's actual login flow. That gap is
// exactly why full login can't be driven end-to-end without either a
// cooperating test backend or an injectable HTTP client — see the final
// test report.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/screens/shared/otp_screen.dart';

void main() {
  Widget wrap({String? devOtp}) => MaterialApp(
        home: OtpScreen(mobile: '9876543210', userRole: 'customer', devOtp: devOtp),
      );

  testWidgets('renders the masked mobile number and 4 empty digit boxes', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('+91 98765 43210'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(4));
  });

  // TC-OTP-UI-01 — Verify OTP starts disabled and only enables once all 4
  // boxes are filled.
  testWidgets('Verify OTP enables only once all 4 digits are entered', (tester) async {
    await tester.pumpWidget(wrap());
    final verifyButton = find.widgetWithText(ElevatedButton, 'Verify OTP');
    expect(tester.widget<ElevatedButton>(verifyButton).onPressed, isNull);

    final boxes = find.byType(TextField);
    for (var i = 0; i < 3; i++) {
      await tester.enterText(boxes.at(i), '1');
      await tester.pump();
    }
    expect(tester.widget<ElevatedButton>(verifyButton).onPressed, isNull); // still only 3/4

    await tester.enterText(boxes.at(3), '1');
    await tester.pump();
    expect(tester.widget<ElevatedButton>(verifyButton).onPressed, isNotNull);
  });

  // TC-OTP-UI-02 — entering a digit in a box (except the last) advances
  // focus to the next box automatically, matching the real 4-box OTP UX.
  testWidgets('entering a digit advances focus to the next box', (tester) async {
    await tester.pumpWidget(wrap());
    final boxes = find.byType(TextField);
    final secondBoxFocusNode = tester.widget<TextField>(boxes.at(1)).focusNode!;

    await tester.enterText(boxes.at(0), '5');
    await tester.pump();

    expect(secondBoxFocusNode.hasFocus, isTrue);
  });

  group('dev OTP banner', () {
    testWidgets('is hidden when no devOtp is supplied (the real navigation path)', (tester) async {
      await tester.pumpWidget(wrap());
      expect(find.textContaining('DEV — OTP'), findsNothing);
    });

    // TC-OTP-UI-03 — tapping the dev banner fills all 4 boxes at once and
    // shows the "auto-filled from SMS" confirmation banner — exercises the
    // same _fillOtp() code path real SMS autofill would use.
    testWidgets('tapping the dev OTP banner fills all 4 boxes', (tester) async {
      await tester.pumpWidget(wrap(devOtp: '1234'));
      expect(find.textContaining('DEV — OTP: 1234'), findsOneWidget);

      await tester.tap(find.textContaining('DEV — OTP: 1234'));
      await tester.pump();

      final boxes = find.byType(TextField);
      for (var i = 0; i < 4; i++) {
        expect(tester.widget<TextField>(boxes.at(i)).controller!.text, '1234'[i]);
      }
      expect(find.text('OTP auto-filled from SMS'), findsOneWidget);

      final verifyButton = find.widgetWithText(ElevatedButton, 'Verify OTP');
      expect(tester.widget<ElevatedButton>(verifyButton).onPressed, isNotNull);
    });
  });

  group('resend countdown', () {
    testWidgets('starts at 60 seconds with Resend OTP not yet available', (tester) async {
      await tester.pumpWidget(wrap());
      expect(find.text('Resend OTP in'), findsOneWidget);
      expect(find.text('00:60'), findsOneWidget);
      expect(find.text('Resend OTP'), findsNothing);
    });

    // TC-OTP-UI-04 — after the 60s countdown elapses, "Resend OTP" becomes
    // tappable — verified here via pumpAndSettle-style ticking rather than
    // actually tapping it (tapping fires a real network call, per this
    // file's header comment).
    testWidgets('Resend OTP becomes available once the countdown reaches zero', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 61));

      expect(find.text("Didn't receive it?"), findsOneWidget);
      expect(find.text('Resend OTP'), findsOneWidget);
    });
  });
}
