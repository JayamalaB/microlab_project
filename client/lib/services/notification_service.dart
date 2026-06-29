import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'socket_service.dart';

// Must be a top-level function — runs in a separate isolate when the app is terminated.
// FCM automatically shows the notification in the system tray in this state;
// this handler just ensures Firebase is ready if we need to do extra work later.
@pragma('vm:keep')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage _) async {}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _localNotifs = FlutterLocalNotificationsPlugin();

  static const _channelId   = 'booking_requests';
  static const _channelName = 'Booking Requests';

  Future<void> initialize() async {
    // Create Android notification channel — must match what the server sends.
    await _localNotifs
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
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
    );

    // Android 13+ requires an explicit runtime permission grant.
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('[FCM] permission: ${settings.authorizationStatus}');

    // When the app is in the foreground FCM does not auto-show a notification,
    // so we display one manually via flutter_local_notifications.
    FirebaseMessaging.onMessage.listen(_onForeground);

    // Keep the stored token fresh if Firebase rotates it.
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      SocketService.instance.updateFcmToken(token);
      debugPrint('[FCM] token refreshed');
    });

    debugPrint('[FCM] NotificationService initialized');
  }

  // Call once after technician login to fetch and store the device token.
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

  void _onForeground(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    // Socket.IO already shows the booking overlay when the app is open —
    // show a heads-up notification so the sound/vibration still fires.
    _localNotifs.show(
      message.hashCode,
      n.title,
      n.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
        ),
      ),
    );
  }
}
