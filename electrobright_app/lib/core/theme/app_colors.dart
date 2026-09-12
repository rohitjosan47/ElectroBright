import 'package:flutter/material.dart';

/// Curated color tokens for the ElectroBright Cyber-Glow design system.
class AppColors {
  // Backgrounds & Surfaces
  static const Color background = Color(0xFF090C12);
  static const Color backgroundElevated = Color(0xFF0E131E);
  static const Color cardSurface = Color(0xFF131A27);
  static const Color cardSurfaceSecondary = Color(0xFF1B2334);
  static const Color cardBorder = Color(0xFF243048);
  static const Color cardBorderGlow = Color(0xFF3B4D72);

  // Vibrant Accents
  static const Color cyanAccent = Color(0xFF00E5FF);
  static const Color pinkAccent = Color(0xFFFF006E);
  static const Color amberAccent = Color(0xFFFF9E00);
  static const Color purpleAccent = Color(0xFF7928CA);
  static const Color greenAccent = Color(0xFF00F5A0);
  static const Color redAccent = Color(0xFFFF2A4B);

  // LED Channel Specific
  static const Color channelRed = Color(0xFFFF3355);
  static const Color channelGreen = Color(0xFF00FF88);
  static const Color channelBlue = Color(0xFF0099FF);
  static const Color channelWhite = Color(0xFFFFF7E6);

  // Text Hierarchy
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // Gradients
  static const LinearGradient cyanPurpleGradient = LinearGradient(
    colors: [cyanAccent, purpleAccent],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient fieryOrangeGradient = LinearGradient(
    colors: [pinkAccent, amberAccent],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
