import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // Brand
  static const Color brandGreen = Color(0xFF127D3B);
  static const Color brandGreenLight = Color(0xFFB8D8C4);
  static const Color brandGreenSurface = Color(0xFFE7F2EB);
  static const Color brandGreenMid = Color(0xFF0D5829);

  // Neutral
  static const Color white = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF9F9F8);
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF757575);
  static const Color textHint = Color(0xFF9E9E9E);
  static const Color divider = Color(0xFFE0E0E0);

  // Semantic
  static const Color blue = Color(0xFF1565C0);
  static const Color blueSurface = Color(0xFFEEF4FB);
  static const Color amber = Color(0xFFE65100);
  static const Color amberSurface = Color(0xFFFEF6EE);
  static const Color error = Color(0xFFC62828);
}

class AppTheme {
  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.brandGreen,
          primary: AppColors.brandGreen,
          surface: AppColors.white,
        ),
        textTheme: GoogleFonts.dmSansTextTheme(),
        scaffoldBackgroundColor: AppColors.white,
        // Same look for every snack bar, including ones not built through
        // AppMessages (lib/utils/app_messages.dart).
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
        ),
      );
}
