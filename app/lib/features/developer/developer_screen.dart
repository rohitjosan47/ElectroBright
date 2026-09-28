import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/model/fixture.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/settings_list.dart';
import '../../design/tokens/tokens.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';
import '../home/presence.dart';
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
              for (final Fixture f in fixtures) _LightRow(fixture: f),
            ],
          ),
      ],
    );
  }
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
