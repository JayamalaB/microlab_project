import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/screens/shared/splash_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

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
