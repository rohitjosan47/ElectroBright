import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  static ThemeData get darkTheme {
    final baseTypography = GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      primaryColor: AppColors.cyanAccent,
      textTheme: baseTypography.copyWith(
        headlineLarge: baseTypography.headlineLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        headlineMedium: baseTypography.headlineMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleLarge: baseTypography.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: baseTypography.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseTypography.bodyLarge?.copyWith(
          color: AppColors.textPrimary,
        ),
        bodyMedium: baseTypography.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
        ),
        bodySmall: baseTypography.bodySmall?.copyWith(
          color: AppColors.textMuted,
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.cyanAccent,
        inactiveTrackColor: AppColors.cardSurfaceSecondary,
        thumbColor: Colors.white,
        overlayColor: Color(0x3300E5FF),
        trackHeight: 6.0,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10.0, elevation: 4.0),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.cyanAccent;
          return AppColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.cyanAccent.withOpacity(0.3);
          return AppColors.cardSurfaceSecondary;
        }),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.backgroundElevated,
        modalBackgroundColor: AppColors.backgroundElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
        ),
      ),
    );
  }

  /// Glassmorphic container decoration helper.
  static BoxDecoration glassBoxDecoration({
    Color? color,
    Color? borderColor,
    double borderRadius = 18.0,
    bool glow = false,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.cardSurface.withOpacity(0.85),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? (glow ? AppColors.cardBorderGlow : AppColors.cardBorder),
        width: 1.2,
      ),
      boxShadow: glow
          ? [
              BoxShadow(
                color: (borderColor ?? AppColors.cyanAccent).withOpacity(0.2),
                blurRadius: 16.0,
                spreadRadius: 1.0,
              )
            ]
          : [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 12.0,
                offset: const Offset(0, 4),
              )
            ],
    );
  }
}
