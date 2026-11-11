import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/model/fixture.dart';
import '../../app/app_session.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/components/settings_list.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';
import '../home/presence.dart';
import 'developer_tools.dart';
import 'light_developer_screen.dart';

/// Settings → Developer: every saved light with its type, firmware version
/// and connection state; a light opens its developer page.
class DeveloperScreen extends ConsumerWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<Fixture> fixtures = ref.watch(fixturesProvider);
    return SettingsPage(
      title: l.developer,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.m),
          child: Text(
            fixtures.isEmpty ? l.homeEmpty : l.developerLightsNote,
            style: settingsDetailStyle(context),
          ),
        ),
        if (fixtures.isNotEmpty)
          SettingsSection(
            children: <Widget>[
              for (int i = 0; i < fixtures.length; i++) ...<Widget>[
                // Slim separators, as in a group's light list.
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: Space.m,
                    endIndent: Space.m,
                    color: settingsInk(context).withValues(alpha: 0.12),
                  ),
                _LightRow(fixture: fixtures[i]),
              ],
            ],
          ),
        const SizedBox(height: Space.m),
        const SettingsSection(children: <Widget>[_ResetAppRow()]),
      ],
    );
  }
}

const Color _danger = Color(0xFFE5484D);

/// "Reset app": after a confirmation, erases everything the app saved and
/// returns to onboarding, as after a fresh install.
class _ResetAppRow extends ConsumerWidget {
  const _ResetAppRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    return ListTile(
      key: const ValueKey<String>('dev-reset-app'),
      leading: const Icon(Icons.restart_alt_rounded, color: _danger),
      title: Text(
        l.resetApp,
        style: settingsTitleStyle(context).copyWith(color: _danger),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: Space.xxs),
        child: Text(l.resetAppHint, style: settingsDetailStyle(context)),
      ),
      onTap: () => unawaited(_confirm(context, ref)),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l = AppLocalizations.of(context);
    final AppController app = ref.read(appSessionProvider.notifier);
    if (!app.canReset) {
      showGlassToast(context, l.resetAppBusy, icon: Icons.downloading_rounded);
      return;
    }
    final Haptics haptics = HapticsScope.of(context);
    haptics.play(HapticEvent.warning);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded, color: _danger, size: 32),
        title: Text(l.resetApp),
        content: Text(l.resetAppConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const ValueKey<String>('dev-reset-app-confirm'),
            style: FilledButton.styleFrom(backgroundColor: _danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.erase),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted || !app.canReset) return;
    final ProviderContainer container = ProviderScope.containerOf(
      context,
      listen: false,
    );
    final NavigatorState nav = Navigator.of(context);
    haptics.play(HapticEvent.success);
    // Onboarding takes over underneath at once; erasing finishes behind it.
    final Future<void> done = app.reset();
    container.invalidate(developerToolsProvider);
    nav.popUntil((Route<dynamic> r) => r.isFirst);
    await done;
  }
}

/// A quiet credit line at the foot of the developer pages.
class DeveloperCredit extends StatelessWidget {
  const DeveloperCredit({super.key, this.subtle = false});

  /// A fainter, smaller footnote for the welcome screen.
  final bool subtle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: subtle
        ? EdgeInsets.zero
        : const EdgeInsets.only(top: Space.l, bottom: Space.s),
    child: Semantics(
      link: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(
          launchUrl(_instagram, mode: LaunchMode.externalApplication),
        ),
        child: Opacity(
          opacity: subtle ? 0.28 : 0.45,
          child: Text(
            'Developer · @rohit_josan12',
            textAlign: TextAlign.center,
            style: subtle
                ? Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.2,
                  )
                : Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    ),
  );

  static final Uri _instagram = Uri.parse(
    'https://www.instagram.com/rohit_josan12/',
  );
}

class _LightRow extends ConsumerWidget {
  const _LightRow({required this.fixture});
  final Fixture fixture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final Fixture f = fixture;
    final (LinkPhase phase, EbIncompatibility? why, String? live) = ref.watch(
      fixtureStatusProvider(f.id).select(
        (FixtureStatus s) =>
            (s.phase, s.incompatibility, s.view?.firmware?.version.version),
      ),
    );
    final bool setup = f.setupNeeded || why == EbIncompatibility.setupNeeded;
    final String? version = live ?? f.identity?.firmwareVersion;
    final Color fg = settingsInk(context);
    return ListTile(
      key: ValueKey<String>('dev-light-${f.id}'),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.m,
        vertical: Space.xxs,
      ),
      title: Text(f.name, style: settingsTitleStyle(context)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: Space.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (setup)
              const SetupNeededBadge()
            else
              FixtureTypeBadge(layout: f.layout, whitePoints: f.whitePoints),
            const SizedBox(height: Space.xxs),
            Text(
              '${version == null ? l.firmwareNotRead : l.firmwareVersionShort(version)}'
              ' · ${presenceOf(l, phase, why)}',
              style: settingsDetailStyle(context),
            ),
          ],
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: fg),
      onTap: () => unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LightDeveloperScreen(fixtureId: f.id),
          ),
        ),
      ),
    );
  }
}
