import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'booking_notification_service.dart';
import 'socket_service.dart';

// ─── FCM background handler ───────────────────────────────────────────────────
//
// Runs in a SEPARATE Dart isolate when the app is killed or backgrounded.
// Cannot access main-isolate singletons (SocketService, BookingNotificationService).
// Creates its own FlutterLocalNotificationsPlugin to show the booking notification.
//
// For this to be called, the server must send a DATA-ONLY FCM message
// (no "notification" field). If "notification" is present, FCM shows it
// automatically and this handler is NEVER invoked.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] != 'booking_request') return;

  const channelId   = 'booking_requests';
  const channelName = 'Booking Requests';

  final plugin = FlutterLocalNotificationsPlugin();

  // Channel must be created in every isolate that shows notifications.
  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
    channelId,
    channelName,
    description: 'Incoming booking request alerts for technicians',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  ));

  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationAction,
  );

  // FCM data values are all strings — SocketBooking.fromJson handles this.
  final data    = Map<String, dynamic>.from(message.data);
  final booking = SocketBooking.fromJson(data);
  final name    = booking.patientName.isEmpty ? 'Patient' : booking.patientName;
  final address = booking.patientAddress.isEmpty ? 'Location pending' : booking.patientAddress;

  await plugin.show(
    booking.bookingId,
    'New Booking Request',
    '$name · #${booking.bookingId}',
    NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        timeoutAfter: 40000,
        styleInformation: BigTextStyleInformation(
          '$name · Booking #${booking.bookingId}\n'
          '📍 $address\n'
          '🕐 ${formatBookingTime(booking.createdAt)}',
        ),
        actions: const [
          AndroidNotificationAction(
            'accept_booking',
            'Accept',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'decline_booking',
            'Decline',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
    ),
    payload: jsonEncode(data),
  );

  // Bridge to main isolate: SharedPreferences is the only cross-isolate
  // store available here. The main isolate reads and clears this on resume.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_fcm_booking', jsonEncode(data));
  } catch (_) {}
}

// ─── NotificationService ──────────────────────────────────────────────────────

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _localNotifs = FlutterLocalNotificationsPlugin();

  static const _channelId   = 'booking_requests';
  static const _channelName = 'Booking Requests';

  Future<void> initialize() async {
    // Create HIGH-priority channel for booking request alerts.
    await _localNotifs
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Incoming booking request alerts for technicians',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));

    await _localNotifs.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      // Fires when user taps a notification or action button while app is running
      // (foreground or background). Does NOT fire for cold-start taps — handled
      // below via getNotificationAppLaunchDetails().
      onDidReceiveNotificationResponse: (response) {
        BookingNotificationService.instance.handleNotificationAction(response);
      },
      // Required parameter — actions with showsUserInterface: true bring the app
      // to the foreground, so the main-isolate callback above handles everything.
      onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationAction,
    );

    // Cold-start: app was killed and user tapped the local notification.
    // onDidReceiveNotificationResponse does NOT fire in this case on Android —
    // the launch detail must be read explicitly before the dashboard mounts.
    final launchDetails = await _localNotifs.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      final response = launchDetails!.notificationResponse;
      if (response != null) {
        BookingNotificationService.instance.handleNotificationAction(response);
      }
    }

    // Android 13+ explicit runtime permission.
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('[FCM] permission: ${settings.authorizationStatus}');

    // Foreground FCM messages (data-only — no notification field from server).
    FirebaseMessaging.onMessage.listen(_onForeground);

    // Keep token fresh if Firebase rotates it.
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      SocketService.instance.updateFcmToken(token);
      debugPrint('[FCM] token refreshed');
    });

    debugPrint('[FCM] NotificationService initialized');
  }

  // Call once after technician login.
  Future<void> loadToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        SocketService.instance.updateFcmToken(token);
        debugPrint('[FCM] token loaded: ...${token.substring(token.length - 10)}');
      }
    } catch (e) {
      debugPrint('[FCM] getToken failed: $e');
    }
  }

  // Fires when a data-only FCM message arrives while the app is in FOREGROUND.
  // Socket.IO delivers the same booking simultaneously; BookingNotificationService
  // dedupes via _lastShownAt (5s window) so only one notification (or overlay) shows.
  void _onForeground(RemoteMessage message) {
    if (message.data['type'] != 'booking_request') return;
    // If socket is connected, _listenToSocket() on the dashboard handles it
    // (overlay or notification) — skip to avoid duplicate heads-up.
    if (SocketService.instance.isConnected) return;
    final data    = Map<String, dynamic>.from(message.data);
    final booking = SocketBooking.fromJson(data);
    BookingNotificationService.instance.showBookingNotification(booking);
  }
}
