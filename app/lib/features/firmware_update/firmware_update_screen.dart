import 'package:flutter/material.dart';

import '../../design/canvas/ambient_canvas.dart';
import '../../design/components/glass_controls.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';

/// Why a light cannot be driven, and what to do about it.
class FirmwareUpdateScreen extends StatelessWidget {
  const FirmwareUpdateScreen({
    required this.name,
    required this.incompatibility,
    this.detail,
    this.onRetry,
    this.onForget,
    super.key,
  });

  final String name;
  final EbIncompatibility? incompatibility;
  final String? detail;
  final VoidCallback? onRetry;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final (String title, String body) = switch (incompatibility) {
      EbIncompatibility.legacyFirmware => (l.fwUpdateTitle, l.fwUpdateBody),
      EbIncompatibility.unknownLayout => (l.presenceNewerApp, l.fwNewerAppBody),
      _ => (l.presenceUnexpected, l.fwUnexpectedBody),
    };
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientCanvas(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(Space.gutter),
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: GlassIconButton(
                  icon: Icons.chevron_left_rounded,
                  label: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(height: Space.l),
              GlassSurface(
                padding: const EdgeInsets.all(Space.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.system_update_rounded, size: 40),
                    const SizedBox(height: Space.s),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: Space.m),
                    Text(body),
                    if (detail != null) ...<Widget>[
                      const SizedBox(height: Space.s),
                      SelectableText(
                        detail!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Space.l),
              if (onRetry != null)
                FilledButton(onPressed: onRetry, child: Text(l.tryAgain)),
              if (onForget != null)
                TextButton(onPressed: onForget, child: Text(l.forgetLight)),
            ],
          ),
        ),
      ),
    );
  }
}
