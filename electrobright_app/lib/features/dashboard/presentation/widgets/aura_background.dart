import 'dart:ui';
import 'package:flutter/material.dart';

/// Dynamic Ambient Aura: Projects a soft, glowing Gaussian-blurred field
/// behind the app interface that mirrors the physical fixture's live light color.
class AuraBackground extends StatelessWidget {
  final Color activeColor;
  final Widget child;

  const AuraBackground({
    super.key,
    required this.activeColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Dim the color slightly so it accents rather than overwhelms the dark theme
    final auraColor = activeColor.withOpacity(0.22);

    return Stack(
      children: [
        // Deep obsidian canvas base
        Container(
          color: const Color(0xFF090C12),
        ),

        // Top-center ambient glow orb
        Positioned(
          top: -100,
          left: MediaQuery.of(context).size.width * 0.15,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: auraColor,
            ),
          ),
        ),

        // Bottom-right secondary subtle ambient orb
        Positioned(
          bottom: 40,
          right: -80,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: auraColor.withOpacity(0.12),
            ),
          ),
        ),

        // Heavy backdrop blur filter to create ethereal luminescence
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 85, sigmaY: 85),
          child: Container(
            color: Colors.transparent,
          ),
        ),

        // Foreground application content
        child,
      ],
    );
  }
}
