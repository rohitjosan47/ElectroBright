import 'package:flutter/material.dart';

class ModeDefinition {
  final int id;
  final String name;
  final String description;
  final IconData icon;
  final LinearGradient accentGradient;
  final bool hasSpeed;
  final bool hasFrequency;
  final bool hasColorMode;
  final bool hasDualCustomColors;

  /// UI name of the speed slider for this mode — describes what it really does.
  final String speedLabel;

  /// UI name of the frequency slider for this mode.
  final String frequencyLabel;

  const ModeDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.accentGradient,
    this.hasSpeed = false,
    this.hasFrequency = false,
    this.hasColorMode = false,
    this.hasDualCustomColors = false,
    this.speedLabel = 'Speed',
    this.frequencyLabel = 'Frequency',
  });

  // ╔══════════════════════════════════════════════════════════════════════╗
  // ║  SYNC NOTICE — Keep in sync with the firmware mode registry        ║
  // ║                                                                    ║
  // ║  firmware/ElectroBright/src/render/ModeRegistry.h is the           ║
  // ║  firmware source of truth for which modes support SPEED,           ║
  // ║  FREQUENCY and COLOR_MODE, and for the slider names below.         ║
  // ║  If you change a capability or label here, update it there too.    ║
  // ╚══════════════════════════════════════════════════════════════════════╝
  static const List<ModeDefinition> allModes = [
    ModeDefinition(
      id: 1,
      name: 'Solid Color',
      description: 'Static pure RGBW illumination',
      icon: Icons.lightbulb_outline,
      accentGradient: LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF0072FF)]),
      hasSpeed: false,
      hasFrequency: false,
    ),
    ModeDefinition(
      id: 2,
      name: 'Blink',
      description: 'Periodic pulse with sharp square wave',
      icon: Icons.flash_on,
      accentGradient: LinearGradient(colors: [Color(0xFFFFEA00), Color(0xFFFF9100)]),
      hasSpeed: false,
      hasFrequency: true,
      frequencyLabel: 'Blink Rate',
    ),
    ModeDefinition(
      id: 3,
      name: 'Breath',
      description: 'Smooth organic sinusoidal respiration',
      icon: Icons.air,
      accentGradient: LinearGradient(colors: [Color(0xFF00F5A0), Color(0xFF00D9F5)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Breath Shape',
      frequencyLabel: 'Breathing Rate',
    ),
    ModeDefinition(
      id: 4,
      name: 'Fireworks',
      description: 'Rocket launches, explosive bursts & crackles',
      icon: Icons.auto_awesome,
      accentGradient: LinearGradient(colors: [Color(0xFFFF0055), Color(0xFFFFAA00)]),
      hasSpeed: true,
      hasFrequency: true,
      hasColorMode: true,
      speedLabel: 'Burst Speed',
      frequencyLabel: 'Launch Rate',
    ),
    ModeDefinition(
      id: 5,
      name: 'TV Simulator',
      description: 'Dynamic ambient broadcast flicker & scenes',
      icon: Icons.tv,
      accentGradient: LinearGradient(colors: [Color(0xFF7000FF), Color(0xFF00E5FF)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Scene Pace',
      frequencyLabel: 'Cuts & Flicker',
    ),
    ModeDefinition(
      id: 6,
      name: 'Thunderstorm',
      description: 'Ominous deep rumble and violent lightning',
      icon: Icons.thunderstorm,
      accentGradient: LinearGradient(colors: [Color(0xFF2979FF), Color(0xFFD500F9)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Stroke Tempo',
      frequencyLabel: 'Strike Rate',
    ),
    ModeDefinition(
      id: 7,
      name: 'Faulty Bulb',
      description: 'Realistic erratic neon tube buzz & sputter',
      icon: Icons.electrical_services,
      accentGradient: LinearGradient(colors: [Color(0xFFFF9100), Color(0xFFFF1744)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Glitch Speed',
      frequencyLabel: 'Glitch Rate',
    ),
    ModeDefinition(
      id: 8,
      name: 'Welding',
      description: 'Arc welding with ignition sparks, spatter and glowing bead',
      icon: Icons.construction,
      accentGradient: LinearGradient(colors: [Color(0xFFFF6D00), Color(0xFF00B0FF)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Weld Length',
      frequencyLabel: 'Weld Gap',
    ),
    ModeDefinition(
      id: 9,
      name: 'Club Lights',
      description: 'High-energy rhythmic strobes & dance beats',
      icon: Icons.nightlife,
      accentGradient: LinearGradient(colors: [Color(0xFFFF007F), Color(0xFF7928CA)]),
      hasSpeed: true,
      hasFrequency: true,
      hasColorMode: true,
      speedLabel: 'Tempo',
      frequencyLabel: 'Energy',
    ),
    ModeDefinition(
      id: 10,
      name: 'Rainbow',
      description: 'Silky 360-degree HSV spectrum flow',
      icon: Icons.looks,
      accentGradient: LinearGradient(colors: [
        Color(0xFFFF0000),
        Color(0xFFFFEA00),
        Color(0xFF00FF00),
        Color(0xFF00E5FF),
        Color(0xFF7000FF)
      ]),
      hasSpeed: false,
      hasFrequency: true,
      frequencyLabel: 'Cycle Speed',
    ),
    ModeDefinition(
      id: 11,
      name: 'Fire',
      description: 'Living hearth fire with turbulent embers',
      icon: Icons.local_fire_department,
      accentGradient: LinearGradient(colors: [Color(0xFFFF1744), Color(0xFFFF9100)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Flicker Speed',
      frequencyLabel: 'Flame Intensity',
    ),
    ModeDefinition(
      id: 12,
      name: 'Police Strobe',
      description: 'Emergency multi-flash wig-wag warning beacons',
      icon: Icons.emergency,
      accentGradient: LinearGradient(colors: [Color(0xFFFF0044), Color(0xFF0066FF)]),
      hasSpeed: true,
      hasFrequency: true,
      hasColorMode: true,
      hasDualCustomColors: true,
      speedLabel: 'Flash Speed',
      frequencyLabel: 'Flashes per Side',
    ),
    ModeDefinition(
      id: 13,
      name: 'Candle',
      description: 'Gentle warm wick dance with air draughts',
      icon: Icons.bedroom_baby,
      accentGradient: LinearGradient(colors: [Color(0xFFFF9E00), Color(0xFFFF5E00)]),
      hasSpeed: true,
      hasFrequency: true,
      speedLabel: 'Flicker Speed',
      frequencyLabel: 'Flicker Depth',
    ),
  ];

  static ModeDefinition getById(int id) {
    return allModes.firstWhere(
      (m) => m.id == id,
      orElse: () => allModes[0],
    );
  }
}
