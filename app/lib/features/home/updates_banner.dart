import 'package:flutter/material.dart';

import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../l10n/app_localizations.dart';

/// Home's quiet note that connected lights have a firmware update ("1 light
/// has an update"); a tap opens the first one's update.
class UpdatesBanner extends StatelessWidget {
  const UpdatesBanner({required this.count, required this.onTap, super.key});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    return Semantics(
      button: true,
      child: GestureDetector(
        key: const ValueKey<String>('home-updates-banner'),
        onTap: onTap,
        child: GlassSurface(
          radius: Radii.medium,
          tinted: false,
          elevated: false,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.m,
            vertical: Space.s,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.arrow_circle_up_rounded,
                size: 20,
                color: PillFill.of(dark: dark).halo,
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  l.updatesBanner(count),
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: fg.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
