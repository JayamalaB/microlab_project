import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/utils/app_messages.dart';

class SocketException implements Exception {
  @override
  String toString() => "SocketException: Failed host lookup: 'chat.neuralarc.com'";
}

void main() {
  group('AppMessages.friendlyError', () {
    test('no internet', () {
      expect(AppMessages.friendlyError(SocketException()), AppMessages.noInternet);
      expect(AppMessages.friendlyError(Exception('ClientException: XMLHttpRequest error.')),
          AppMessages.noInternet);
    });

    test('timeout', () {
      expect(AppMessages.friendlyError(TimeoutException('Future not completed')), AppMessages.timeout);
    });

    test('camera permission', () {
      expect(AppMessages.friendlyError(PlatformException(code: 'camera_access_denied')),
          contains('camera access'));
    });

    test('a reply that is not JSON', () {
      expect(AppMessages.friendlyError(const FormatException('Unexpected character')),
          AppMessages.serverError);
    });

    test('anything else never shows the exception text', () {
      final msg = AppMessages.friendlyError(StateError("Cannot read 'id' of null"));
      expect(msg, AppMessages.genericError);
    });
  });

  group('AppMessages.serverMessage', () {
    const fallback = 'Please try again.';

    test('keeps a plain message', () {
      expect(AppMessages.serverMessage("Your account isn't linked to a MicroLab branch yet.", fallback: fallback),
          "Your account isn't linked to a MicroLab branch yet.");
      expect(AppMessages.serverMessage('Incorrect OTP. 2 attempts remaining.', fallback: fallback),
          'Incorrect OTP. 2 attempts remaining.');
    });

    test('replaces field names, codes and "Server error"', () {
      expect(AppMessages.serverMessage('bookingId is required', fallback: fallback), fallback);
      expect(AppMessages.serverMessage('branch_id is required for lab_visit', fallback: fallback), fallback);
      expect(AppMessages.serverMessage('ER_BAD_FIELD_ERROR: Unknown column', fallback: fallback), fallback);
      expect(AppMessages.serverMessage('Failed to load (500)', fallback: fallback), fallback);
      expect(AppMessages.serverMessage('Server error', fallback: fallback), AppMessages.serverError);
    });

    test('missing or empty → fallback', () {
      expect(AppMessages.serverMessage(null, fallback: fallback), fallback);
      expect(AppMessages.serverMessage('   ', fallback: fallback), fallback);
      expect(AppMessages.serverMessage(42, fallback: fallback), fallback);
    });
  });

  group('AppMessages.paymentError', () {
    test('cancelled vs failed', () {
      expect(AppMessages.paymentError('Payment cancelled'), 'Payment cancelled.');
      expect(AppMessages.paymentError('BAD_REQUEST_ERROR: invalid key'), isNot(contains('BAD_REQUEST')));
    });
  });
}
