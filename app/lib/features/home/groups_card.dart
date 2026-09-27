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

/// Groups on Home: one card, a tappable half per group that exists (both:
/// side by side; one: full width). Each half shows the colours of its first
/// lights and how many are connected. It connects nothing: the count is the
/// group's while its screen is open, else what the lights already report.
class GroupsCard extends StatelessWidget {
  const GroupsCard({required this.kinds, required this.onOpen, super.key});

  /// The groups that exist, colour first.
  final List<GroupKind> kinds;
  final void Function(GroupKind kind) onOpen;

  @override
  Widget build(BuildContext context) {
    final Color fg = ToneScope.darkOf(context)
        ? Colors.white
        : const Color(0xFF15171C);
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).groupsTitle,
      child: GlassSurface(
        key: const ValueKey<String>('groups-card'),
        radius: Radii.large,
        padding: EdgeInsets.zero,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < kinds.length; i++) ...<Widget>[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.m),
                    child: VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: fg.withValues(alpha: 0.12),
                    ),
                  ),
                Expanded(
                  child: _GroupHalf(
                    kind: kinds[i],
                    wide: kinds.length == 1,
                    fg: fg,
                    onOpen: () => onOpen(kinds[i]),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHalf extends ConsumerWidget {
  const _GroupHalf({
    required this.kind,
    required this.wide,
    required this.fg,
    required this.onOpen,
  });
  final GroupKind kind;

  /// The only group: the full width, with a chevron.
  final bool wide;
  final Color fg;
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
    final String status = l.groupConnected(
      ready,
      st.members.length + st.excluded.length,
    );
    final String title = kind == GroupKind.colour
        ? l.groupColourTitle
        : l.groupWhiteTitle;
    final int shown = ids.length < _swatches ? ids.length : _swatches;
    const double orb = 26, step = 16;
    return Semantics(
      button: true,
      label: title,
      value: status,
      child: GestureDetector(
        key: ValueKey<String>('group-card-${kind.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Space.m),
          child: ExcludeSemantics(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: orb + (shown - 1).clamp(0, 3) * step,
                        height: orb,
                        child: Stack(
                          children: <Widget>[
                            for (int i = 0; i < shown; i++)
                              Positioned(
                                left: i * step,
                                child: _Swatch(id: ids[i], size: orb),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Space.s),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: Space.xxs),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.55),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (wide)
                  Icon(
                    Icons.chevron_right_rounded,
                    color: fg.withValues(alpha: 0.6),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One light's colour, as its tile shows it.
class _Swatch extends ConsumerWidget {
  const _Swatch({required this.id, required this.size});
  final String id;
  final double size;

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
    return TileOrb(color: c.color, glow: c.glow, size: size);
  }
}
