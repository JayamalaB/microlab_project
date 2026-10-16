import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:microlab/theme/app_theme.dart';

// One place for the short messages (snack bars) the customer and technician
// apps show, so they all look and read the same:
//
//   AppMessages.success(context, 'Booking confirmed');
//   AppMessages.error(context, AppMessages.friendlyError(e));
//   AppMessages.error(context, AppMessages.serverMessage(body['message'],
//       fallback: 'Could not cancel the booking. Please try again.'));
//
// friendlyError() turns an exception into plain language, and
// serverMessage() keeps a server message only when it is written for people
// — so exception names, HTTP codes and field names never reach the screen.
class AppMessages {
  AppMessages._();

  static const String genericError   = 'Something went wrong. Please try again.';
  static const String serverError    = 'Something went wrong on our side. Please try again in a moment.';
  static const String noInternet     = 'No internet connection. Check your connection and try again.';
  static const String timeout        = 'This is taking longer than usual. Please try again.';

  static void success(BuildContext context, String message, {SnackBarAction? action, Duration? duration}) =>
      _show(context, message, _Kind.success, action: action, duration: duration);

  static void error(BuildContext context, String message, {SnackBarAction? action, Duration? duration}) =>
      _show(context, message, _Kind.error, action: action, duration: duration);

  static void warning(BuildContext context, String message, {SnackBarAction? action, Duration? duration}) =>
      _show(context, message, _Kind.warning, action: action, duration: duration);

  static void info(BuildContext context, String message, {SnackBarAction? action, Duration? duration}) =>
      _show(context, message, _Kind.info, action: action, duration: duration);

  // ── Exception → plain language ────────────────────────────────────────────
  // Matches by type name and text rather than importing dart:io, so the
  // same code works in the web build.
  static String friendlyError(Object? e) {
    if (e == null) return genericError;
    if (e is TimeoutException) return timeout;

    final type = e.runtimeType.toString();
    final text = e.toString();

    if (type.contains('SocketException') ||
        type.contains('ClientException') ||
        type.contains('HandshakeException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Connection reset') ||
        text.contains('Network is unreachable') ||
        text.contains('XMLHttpRequest error')) {
      return noInternet;
    }

    if (type.contains('LocationServiceDisabled')) {
      return 'Location is turned off. Turn it on and try again.';
    }
    if (type.contains('PermissionDenied') || text.contains('denied permissions')) {
      return 'Allow access in your phone\'s Settings, then try again.';
    }

    if (e is PlatformException) {
      final code = e.code.toLowerCase();
      if (code.contains('camera')) {
        return 'Allow camera access in your phone\'s Settings, then try again.';
      }
      if (code.contains('photo') || code.contains('gallery') || code.contains('storage')) {
        return 'Allow photo access in your phone\'s Settings, then try again.';
      }
      if (code.contains('denied') || code.contains('permission')) {
        return 'Allow access in your phone\'s Settings, then try again.';
      }
    }

    // A reply that wasn't JSON (e.g. an HTML error page from a proxy).
    if (type.contains('FormatException')) return serverError;

    return genericError;
  }

  // ── Razorpay error → plain language ───────────────────────────────────────
  // Razorpay's own error text (e.g. "BAD_REQUEST_ERROR: …") is for the log.
  static bool isPaymentCancelled(String? razorpayMessage) => razorpayMessage == 'Payment cancelled';

  static String paymentError(String? razorpayMessage) {
    if (isPaymentCancelled(razorpayMessage)) return 'Payment cancelled.';
    debugPrint('[Payment] Razorpay error: $razorpayMessage');
    return 'The payment didn\'t go through. Please try again or use another payment method.';
  }

  // ── Server message → shown only when it is written for people ─────────────
  // Server replies normally carry plain messages ("Your account isn't linked
  // to a MicroLab branch yet…"), but a few validation replies still name
  // fields ("bookingId is required"), and an older server may send
  // "Server error". Those get the caller's fallback instead.
  static String serverMessage(Object? message, {required String fallback}) {
    if (message is! String) return fallback;
    final m = message.trim();
    if (m.isEmpty) return fallback;
    if (m == 'Server error' || m == 'Internal server error') return serverError;
    if (_looksTechnical(m)) return fallback;
    return m;
  }

  static final List<RegExp> _technicalPatterns = [
    RegExp(r'\b[a-z]+_[a-z0-9_]+\b'),        // snake_case field / table names
    RegExp(r'\b[a-z]+[A-Z][A-Za-z0-9]*\b'),  // camelCase field names (bookingId)
    RegExp(r'Exception|Error:|\bER_[A-Z_]+|\bSQL\b|\bECONN|\bETIMEDOUT|\bHTTP\b|\bnull\b|\bundefined\b|\bstack\b',
        caseSensitive: false),
    RegExp(r'\(\d{3}\)'),                    // "(500)"
  ];

  static bool _looksTechnical(String m) =>
      m.length > 220 || _technicalPatterns.any((p) => p.hasMatch(m));

  // ── Display ────────────────────────────────────────────────────────────────
  static void _show(BuildContext context, String message, _Kind kind,
      {SnackBarAction? action, Duration? duration}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(kind.icon, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13.5))),
        ]),
        backgroundColor: kind.color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: duration ?? kind.duration,
        action: action,
      ));
  }
}

enum _Kind {
  success(AppColors.brandGreen, Icons.check_circle_rounded, Duration(seconds: 3)),
  error(AppColors.error, Icons.error_rounded, Duration(seconds: 5)),
  warning(AppColors.amber, Icons.warning_amber_rounded, Duration(seconds: 5)),
  info(AppColors.blue, Icons.info_rounded, Duration(seconds: 4));

  const _Kind(this.color, this.icon, this.duration);
  final Color color;
  final IconData icon;
  final Duration duration;
}
