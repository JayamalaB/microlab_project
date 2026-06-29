import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/services/notification_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/screens/shared/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase + push notifications — Android only for now.
  // Web requires explicit FirebaseOptions (from FlutterFire CLI); that will be
  // wired up when web notification support is added in a later phase.
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await Firebase.initializeApp();
    await NotificationService.instance.initialize();
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
