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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase, foreground service, push notifications — Android only.
  // flutter_foreground_task uses dart:isolate which is not available on Web.
  if (!kIsWeb) {
    try {
      FlutterForegroundTask.initCommunicationPort();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await Firebase.initializeApp();
      await NotificationService.instance.initialize();
      BookingNotificationService.instance.init();
      ForegroundService.instance.init();
    } catch (e) {
      // Missing/invalid google-services.json (e.g. local dev builds) should
      // not take down the whole app — push notifications just stay disabled.
      debugPrint('Firebase/notification init skipped: $e');
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
      home: const SplashScreen(),
    );
  }
}
