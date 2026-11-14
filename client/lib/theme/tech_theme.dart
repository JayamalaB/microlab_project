import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Technician app design tokens and theme.
//
// The customer app is untouched: AppTheme.theme (the MaterialApp theme) is
// unchanged. Technician screens opt in by wrapping their content in
// TechThemeScope, which layers the component defaults below on top of the
// app theme for that subtree only. Dialogs and bottom sheets opened from
// inside the scope pick it up too (showDialog / showModalBottomSheet carry
// the caller's theme into the popup).
//
// Brand colour stays AppColors.brandGreen (#127D3B), shared with the customer
// app; there is no separate technician colour.
// ─────────────────────────────────────────────────────────────────────────────

/// Corner radii: one scale for the whole technician app.
abstract final class TechRadius {
  static const double sm = 8;   // chips, small badges, thumbnails
  static const double md = 12;  // inputs, buttons, inner tiles
  static const double lg = 16;  // cards, option cards, dialogs' inner blocks
  static const double xl = 24;  // dialogs and bottom sheets

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius sheetTop = BorderRadius.vertical(top: Radius.circular(xl));
}

/// Spacing scale (4-pt grid).
abstract final class TechSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  /// Side padding for screens, sheets and dialogs.
  static const double gutter = 20;
}

/// Standard sizes.
abstract final class TechSize {
  static const double buttonHeight = 52;
  static const double buttonHeightCompact = 44;
  static const double minTouch = 48;
  static const double sheetMaxWidth = 560; // tablets: keep sheets readable
  static const double dialogMaxWidth = 420;
}

/// Colours. Brand colours come from AppColors; the semantic tones replace the
/// many one-off hex values in the technician screens (3 reds, 4 oranges, …).
abstract final class TechColors {
  static const Color brand = AppColors.brandGreen;
  static const Color brandSurface = AppColors.brandGreenSurface;
  static const Color brandDark = AppColors.brandGreenMid;

  static const Color textPrimary = AppColors.textPrimary;
  static const Color textSecondary = AppColors.textSecondary;
  static const Color textHint = AppColors.textHint;
  static const Color border = AppColors.divider;
  static const Color surfaceMuted = AppColors.background;

  static const Color success = AppColors.brandGreen;
  static const Color successSurface = AppColors.brandGreenSurface;
  static const Color error = AppColors.error;
  static const Color errorSurface = Color(0xFFFDECEC);
  static const Color warning = AppColors.amber;
  static const Color warningSurface = AppColors.amberSurface;
  static const Color info = AppColors.blue;
  static const Color infoSurface = AppColors.blueSurface;
}

/// A semantic tone for icons, chips, banners and dialogs.
enum TechTone {
  brand(TechColors.brand, TechColors.brandSurface),
  success(TechColors.success, TechColors.successSurface),
  error(TechColors.error, TechColors.errorSurface),
  warning(TechColors.warning, TechColors.warningSurface),
  info(TechColors.info, TechColors.infoSurface),
  neutral(TechColors.textSecondary, TechColors.surfaceMuted);

  const TechTone(this.color, this.surface);
  final Color color;
  final Color surface;
}

/// Text styles, on top of the app's DM Sans text theme.
abstract final class TechText {
  static const TextStyle sheetTitle = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: TechColors.textPrimary, letterSpacing: -0.2);
  static const TextStyle dialogTitle = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: TechColors.textPrimary, letterSpacing: -0.2);
  // Ladder: 16 sheet/dialog title › 14 section › 13.5 card › 13 body ›
  // 12.5 secondary › 11.5 caption. Bold only on titles; cards/buttons w600.
  static const TextStyle sectionTitle = TextStyle(
      fontSize: 14, fontWeight: FontWeight.w600, color: TechColors.textPrimary);
  static const TextStyle cardTitle = TextStyle(
      fontSize: 13.5, fontWeight: FontWeight.w600, color: TechColors.textPrimary);
  static const TextStyle body = TextStyle(
      fontSize: 13, color: TechColors.textPrimary, height: 1.4);
  static const TextStyle bodySecondary = TextStyle(
      fontSize: 12.5, color: TechColors.textSecondary, height: 1.4);
  static const TextStyle caption = TextStyle(
      fontSize: 11.5, color: TechColors.textSecondary, height: 1.35);
  static const TextStyle overline = TextStyle(
      fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: TechColors.brand);
  static const TextStyle button = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
}

abstract final class TechTheme {
  /// The technician component defaults layered over [base] (the app theme).
  static ThemeData from(ThemeData base) {
    const buttonShape = RoundedRectangleBorder(borderRadius: TechRadius.mdAll);
    const minSize = Size(64, TechSize.buttonHeightCompact);

    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: TechColors.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: TechColors.border,
          disabledForegroundColor: TechColors.textHint,
          minimumSize: minSize,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: buttonShape,
          textStyle: TechText.button,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TechColors.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: TechColors.border,
          disabledForegroundColor: TechColors.textHint,
          elevation: 0,
          minimumSize: minSize,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: buttonShape,
          textStyle: TechText.button,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TechColors.brand,
          side: const BorderSide(color: TechColors.brand, width: 1.2),
          minimumSize: minSize,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: buttonShape,
          textStyle: TechText.button.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: TechColors.brand,
          minimumSize: const Size(48, TechSize.minTouch - 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: buttonShape,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: TechRadius.xlAll),
        titleTextStyle: TechText.dialogTitle,
        contentTextStyle: TechText.bodySecondary,
        insetPadding: EdgeInsets.symmetric(horizontal: TechSpace.xl, vertical: TechSpace.xxl),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.white,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: TechRadius.sheetTop),
        showDragHandle: false, // TechSheetFrame draws its own, same everywhere
        constraints: BoxConstraints(maxWidth: TechSize.sheetMaxWidth),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: const TextStyle(fontSize: 13, color: TechColors.textHint),
        labelStyle: const TextStyle(fontSize: 13, color: TechColors.textSecondary),
        floatingLabelStyle: const TextStyle(color: TechColors.brand, fontWeight: FontWeight.w600),
        helperStyle: TechText.caption,
        errorStyle: const TextStyle(fontSize: 12, color: TechColors.error),
        border: _inputBorder(TechColors.border),
        enabledBorder: _inputBorder(TechColors.border),
        focusedBorder: _inputBorder(TechColors.brand, width: 1.6),
        errorBorder: _inputBorder(TechColors.error),
        focusedErrorBorder: _inputBorder(TechColors.error, width: 1.6),
        disabledBorder: _inputBorder(TechColors.border.withValues(alpha: 0.6)),
      ),
      cardTheme: const CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: TechRadius.lgAll,
          side: BorderSide(color: TechColors.border),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const RoundedRectangleBorder(borderRadius: TechRadius.smAll),
        side: const BorderSide(color: TechColors.border),
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: TechColors.textPrimary),
      ),
      dividerTheme: const DividerThemeData(color: TechColors.border, thickness: 1, space: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: TechColors.brand),
      checkboxTheme: const CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) => OutlineInputBorder(
        borderRadius: TechRadius.mdAll,
        borderSide: BorderSide(color: color, width: width),
      );
}

/// Applies the technician theme to [child] only. Wrap a technician screen's
/// body (or a whole technician route) in this; nothing outside changes.
class TechThemeScope extends StatelessWidget {
  final Widget child;
  const TechThemeScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Theme(data: TechTheme.from(Theme.of(context)), child: child);
}
