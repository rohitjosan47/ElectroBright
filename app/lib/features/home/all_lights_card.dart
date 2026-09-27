import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/model/fixture.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/group_capabilities.dart';
import '../../sessions/group_session.dart';
import 'light_tile.dart';

/// All Lights on Home, styled like a light tile: the colours of the first
/// lights and how many are connected. It connects nothing: the count is the
/// group's while All Lights is open, else what the lights already report.
class AllLightsCard extends ConsumerWidget {
  const AllLightsCard({required this.kind, required this.onOpen, super.key});
  final GroupKind kind;
  final VoidCallback onOpen;

  static const int _swatches = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final GroupStatus st = ref.watch(groupStatusProvider(kind));
    final List<String> ids = <String>[
      for (final GroupMember m in st.members) m.id,
    ];
    final int ready = st.active
        ? st.ready
        : ids
              .where(
                (String id) => ref.watch(
                  fixtureStatusProvider(id)
                      .select((FixtureStatus s) => s.phase == LinkPhase.ready),
                ),
              )
              .length;
    // Out of every light of the group, left-out ones included.
    final int saved = st.members.length + st.excluded.length;
    final String status = l.groupConnected(ready, saved);
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    final int shown = ids.length < _swatches ? ids.length : _swatches;
    return Semantics(
      button: true,
      label: l.allLightsTitle,
      value: status,
      child: GestureDetector(
        key: ValueKey<String>('group-card-${kind.name}'),
        onTap: onOpen,
        child: GlassSurface(
          radius: Radii.large,
          padding: const EdgeInsets.all(Space.m),
          child: Row(
            children: <Widget>[
              ExcludeSemantics(
                child: SizedBox(
                  width: 32 + (shown - 1).clamp(0, 3) * 20,
                  height: 32,
                  child: Stack(
                    children: <Widget>[
                      for (int i = 0; i < shown; i++)
                        Positioned(
                          left: i * 20,
                          child: _Swatch(id: ids[i]),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l.allLightsTitle,
                      style: TextStyle(
                        color: fg,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Space.xxs),
                    Text(
                      status,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
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

/// One light's colour, as its tile shows it.
class _Swatch extends ConsumerWidget {
  const _Swatch({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Fixture? f = ref.watch(fixtureProvider(id));
    if (f == null) return const SizedBox.shrink();
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    final ({Color color, bool glow}) c = tileColour(
      ref,
      f,
      ref.watch(fixtureStatusProvider(id).select((FixtureStatus s) => s.state)),
      fg,
    );
    return TileOrb(color: c.color, glow: c.glow, size: 32);
  }
}
