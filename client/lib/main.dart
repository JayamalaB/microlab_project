import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:microlab/services/foreground_service.dart';
import 'package:microlab/services/booking_notification_service.dart';
import 'package:microlab/services/notification_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/screens/shared/splash_screen.dart';
import 'package:microlab/services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase, foreground service, push notifications.
  // flutter_foreground_task uses dart:isolate which is not available on Web.
  //
  // Each step has its own try/catch: a missing Firebase config (no
  // google-services.json / GoogleService-Info.plist, e.g. local dev or iOS
  // builds) must only disable push — it must not skip the foreground service
  // init, otherwise technicians cannot go online.
  if (!kIsWeb) {
    FlutterForegroundTask.initCommunicationPort();
    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('Firebase init skipped: $e');
    }
    try {
      await NotificationService.instance.initialize();
    } catch (e) {
      debugPrint('Notification init skipped: $e');
    }
    try {
      BookingNotificationService.instance.init();
    } catch (e) {
      debugPrint('Booking notification init skipped: $e');
    }
    try {
      ForegroundService.instance.init();
    } catch (e) {
      debugPrint('Foreground service init skipped: $e');
    }
  }

  // Status bar style — transparent for splash
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Lock to portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const MicroLabApp());
}

class MicroLabApp extends StatelessWidget {
  const MicroLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MicroLab',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      navigatorKey: ApiService.navigatorKey,
      home: const SplashScreen(),
    );
  }
}
