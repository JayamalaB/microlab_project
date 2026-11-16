import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Customer app design tokens and theme.
//
// Separate from the technician kit (tech_theme.dart) and from the global
// AppTheme, which stays unchanged. Customer screens opt in by wrapping their
// content in CustomerThemeScope; popups opened from inside the scope pick it
// up too (showDialog / showModalBottomSheet carry the caller's theme).
//
// Brand colour: AppColors.brandGreen (#127D3B), shared with the technician app.
// ─────────────────────────────────────────────────────────────────────────────

/// Corner radii.
abstract final class CxRadius {
  static const double sm = 8;   // chips, thumbnails
  static const double md = 12;  // inputs, buttons, inner tiles
  static const double lg = 16;  // cards
  static const double xl = 24;  // sheets and dialogs

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius sheetTop = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Spacing (4-pt grid).
abstract final class CxSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double gutter = 16; // page side padding
}

/// Sizes.
abstract final class CxSize {
  static const double buttonHeight = 50;
  static const double buttonHeightCompact = 42;
  static const double minTouch = 48;
  static const double sheetMaxWidth = 600;
  static const double dialogMaxWidth = 420;
  static const double contentMaxWidth = 720; // tablets
}

/// Colours. Brand from AppColors; semantic tones replace the many one-off
/// reds / oranges / blues in the customer screens.
abstract final class CxColors {
  static const Color brand = AppColors.brandGreen;
  static const Color brandDark = AppColors.brandGreenMid;
  static const Color brandSurface = AppColors.brandGreenSurface;
  static const Color brandLight = AppColors.brandGreenLight;

  static const Color page = Color(0xFFF5F7F6);   // soft grey-green page
  static const Color surface = Colors.white;
  static const Color surfaceMuted = AppColors.background;
  static const Color border = AppColors.divider;

  static const Color textPrimary = AppColors.textPrimary;
  static const Color textSecondary = AppColors.textSecondary;
  static const Color textHint = AppColors.textHint;

  static const Color success = AppColors.brandGreen;
  static const Color successSurface = AppColors.brandGreenSurface;
  static const Color error = AppColors.error;
  static const Color errorSurface = Color(0xFFFDECEC);
  static const Color warning = AppColors.amber;
  static const Color warningSurface = AppColors.amberSurface;
  static const Color info = AppColors.blue;
  static const Color infoSurface = AppColors.blueSurface;
  static const Color offer = Color(0xFFC2410C);       // discount / offer accent
  static const Color offerSurface = Color(0xFFFFF1E7);
}

enum CxTone {
  brand(CxColors.brand, CxColors.brandSurface),
  success(CxColors.success, CxColors.successSurface),
  error(CxColors.error, CxColors.errorSurface),
  warning(CxColors.warning, CxColors.warningSurface),
  info(CxColors.info, CxColors.infoSurface),
  offer(CxColors.offer, CxColors.offerSurface),
  neutral(CxColors.textSecondary, CxColors.surfaceMuted);

  const CxTone(this.color, this.surface);
  final Color color;
  final Color surface;
}

/// Type scale: 20 page › 17 sheet/dialog › 16 section › 15 card › 14 body ›
/// 13 secondary › 12 caption. Nothing below 11.
abstract final class CxText {
  static const TextStyle pageTitle = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w700, color: CxColors.textPrimary, letterSpacing: -0.3);
  static const TextStyle sheetTitle = TextStyle(
      fontSize: 17, fontWeight: FontWeight.w700, color: CxColors.textPrimary, letterSpacing: -0.2);
  static const TextStyle sectionTitle = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: CxColors.textPrimary);
  static const TextStyle cardTitle = TextStyle(
      fontSize: 15, fontWeight: FontWeight.w600, color: CxColors.textPrimary, height: 1.3);
  static const TextStyle body = TextStyle(
      fontSize: 14, color: CxColors.textPrimary, height: 1.45);
  static const TextStyle bodySecondary = TextStyle(
      fontSize: 13, color: CxColors.textSecondary, height: 1.4);
  static const TextStyle caption = TextStyle(
      fontSize: 12, color: CxColors.textSecondary, height: 1.35);
  static const TextStyle label = TextStyle(
      fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textPrimary);
  static const TextStyle price = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: CxColors.textPrimary);
  static const TextStyle button = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
}

abstract final class CustomerTheme {
  /// Customer component defaults layered over [base] (the app theme).
  static ThemeData from(ThemeData base) {
    const buttonShape = RoundedRectangleBorder(borderRadius: CxRadius.mdAll);
    const minSize = Size(64, CxSize.buttonHeightCompact);
    const pad = EdgeInsets.symmetric(horizontal: 20, vertical: 12);

    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: CxColors.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: CxColors.border,
          disabledForegroundColor: CxColors.textHint,
          minimumSize: minSize, padding: pad, shape: buttonShape,
          textStyle: CxText.button,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CxColors.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: CxColors.border,
          disabledForegroundColor: CxColors.textHint,
          elevation: 0,
          minimumSize: minSize, padding: pad, shape: buttonShape,
          textStyle: CxText.button,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CxColors.brand,
          side: const BorderSide(color: CxColors.brand, width: 1.2),
          minimumSize: minSize, padding: pad, shape: buttonShape,
          textStyle: CxText.button,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: CxColors.brand,
          minimumSize: const Size(48, 40),
          shape: buttonShape,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: CxRadius.xlAll),
        titleTextStyle: CxText.sheetTitle,
        contentTextStyle: CxText.bodySecondary,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.white,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: CxRadius.sheetTop),
        constraints: BoxConstraints(maxWidth: CxSize.sheetMaxWidth),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: const TextStyle(fontSize: 14, color: CxColors.textHint),
        labelStyle: const TextStyle(fontSize: 14, color: CxColors.textSecondary),
        floatingLabelStyle: const TextStyle(color: CxColors.brand, fontWeight: FontWeight.w600),
        helperStyle: CxText.caption,
        errorStyle: const TextStyle(fontSize: 12, color: CxColors.error),
        border: _border(CxColors.border),
        enabledBorder: _border(CxColors.border),
        focusedBorder: _border(CxColors.brand, width: 1.6),
        errorBorder: _border(CxColors.error),
        focusedErrorBorder: _border(CxColors.error, width: 1.6),
        disabledBorder: _border(CxColors.border.withValues(alpha: 0.6)),
      ),
      cardTheme: const CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: CxRadius.lgAll,
          side: BorderSide(color: CxColors.border),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const RoundedRectangleBorder(borderRadius: CxRadius.pill),
        side: const BorderSide(color: CxColors.border),
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: CxColors.textPrimary),
      ),
      dividerTheme: const DividerThemeData(color: CxColors.border, thickness: 1, space: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: CxColors.brand),
      checkboxTheme: const CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      ),
    );
  }

  static OutlineInputBorder _border(Color c, {double width = 1}) => OutlineInputBorder(
        borderRadius: CxRadius.mdAll,
        borderSide: BorderSide(color: c, width: width),
      );
}

/// Applies the customer theme to [child] only; nothing outside changes.
class CustomerThemeScope extends StatelessWidget {
  final Widget child;
  const CustomerThemeScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Theme(data: CustomerTheme.from(Theme.of(context)), child: child);
}
