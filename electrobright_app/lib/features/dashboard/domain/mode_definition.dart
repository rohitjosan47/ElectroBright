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
  });

  // ╔══════════════════════════════════════════════════════════════════════╗
  // ║  SYNC NOTICE — Keep in sync with firmware parseCommand()           ║
  // ║                                                                    ║
  // ║  The MODE_CAPABILITIES:<mode> handler in parseCommand()            ║
  // ║  (ElectroBright_ESP32C3_BLE.ino) is the firmware source of truth   ║
  // ║  for which modes support SPEED, FREQUENCY, and COLOR_MODE.         ║
  // ║  If you add/remove a capability here, verify the firmware branch   ║
  // ║  matches, and vice versa.                                          ║
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
    ),
    ModeDefinition(
      id: 3,
      name: 'Breath',
      description: 'Smooth organic sinusoidal respiration',
      icon: Icons.air,
      accentGradient: LinearGradient(colors: [Color(0xFF00F5A0), Color(0xFF00D9F5)]),
      hasSpeed: false,
      hasFrequency: true,
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
    ),
    ModeDefinition(
      id: 5,
      name: 'TV Simulator',
      description: 'Dynamic ambient broadcast flicker & scenes',
      icon: Icons.tv,
      accentGradient: LinearGradient(colors: [Color(0xFF7000FF), Color(0xFF00E5FF)]),
      hasSpeed: true,
      hasFrequency: true,
    ),
    ModeDefinition(
      id: 6,
      name: 'Thunderstorm',
      description: 'Ominous deep rumble and violent lightning',
      icon: Icons.thunderstorm,
      accentGradient: LinearGradient(colors: [Color(0xFF2979FF), Color(0xFFD500F9)]),
      hasSpeed: true,
      hasFrequency: true,
    ),
    ModeDefinition(
      id: 7,
      name: 'Faulty Bulb',
      description: 'Realistic erratic neon tube buzz & sputter',
      icon: Icons.electrical_services,
      accentGradient: LinearGradient(colors: [Color(0xFFFF9100), Color(0xFFFF1744)]),
      hasSpeed: true,
      hasFrequency: true,
    ),
    ModeDefinition(
      id: 8,
      name: 'Single Dynamic',
      description: 'Autonomous color drift and wave sweeps',
      icon: Icons.waves,
      accentGradient: LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF00F5A0)]),
      hasSpeed: false,
      hasFrequency: true,
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
    ),
    ModeDefinition(
      id: 11,
      name: 'Fire',
      description: 'Living hearth fire with turbulent embers',
      icon: Icons.local_fire_department,
      accentGradient: LinearGradient(colors: [Color(0xFFFF1744), Color(0xFFFF9100)]),
      hasSpeed: true,
      hasFrequency: true,
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
    ),
    ModeDefinition(
      id: 13,
      name: 'Candle',
      description: 'Gentle warm wick dance with air draughts',
      icon: Icons.bedroom_baby,
      accentGradient: LinearGradient(colors: [Color(0xFFFF9E00), Color(0xFFFF5E00)]),
      hasSpeed: true,
      hasFrequency: true,
    ),
  ];

  static ModeDefinition getById(int id) {
    return allModes.firstWhere(
      (m) => m.id == id,
      orElse: () => allModes[0],
    );
  }
}
