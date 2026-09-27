import 'package:flutter/material.dart';

import '../../../design/components/glass_controls.dart';
import '../../../design/haptics/haptics.dart';
import '../../../design/tokens/tokens.dart';
import '../../../l10n/app_localizations.dart';

/// Back, title with a line under it, and the power button (a light's screen,
/// a group).
class ControlHeader extends StatelessWidget {
  const ControlHeader({
    required this.title,
    required this.subtitle,
    required this.on,
    required this.lit,
    required this.fg,
    required this.onPower,
    super.key,
  });
  final String title;
  final Widget subtitle;

  /// On: the power button turns off.
  final bool on;

  /// The power button lit in the light's accent.
  final bool lit;
  final Color fg;
  final VoidCallback? onPower;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return Row(
      children: <Widget>[
        GlassIconButton(
          icon: Icons.chevron_left_rounded,
          label: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: Space.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: Space.xxs),
              subtitle,
            ],
          ),
        ),
        const SizedBox(width: Space.s),
        GlassIconButton(
          icon: Icons.power_settings_new_rounded,
          label: on ? l.powerOff : l.powerOn,
          active: lit,
          haptic: on ? HapticEvent.powerOff : HapticEvent.powerOn,
          onPressed: onPower,
        ),
      ],
    );
  }
}
