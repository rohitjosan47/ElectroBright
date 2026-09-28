import 'package:flutter/material.dart';

import '../canvas/ambient_canvas.dart';
import '../glass/glass_surface.dart';
import '../tokens/tokens.dart';
import 'glass_controls.dart';

/// Ink of settings text: white on dark, near-black on light.
Color settingsInk(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.white
    : const Color(0xFF15171C);

/// A settings row's title.
TextStyle settingsTitleStyle(BuildContext context) => TextStyle(
  color: settingsInk(context),
  fontSize: 15,
  fontWeight: FontWeight.w600,
);

/// A settings row's detail line (and section headings).
TextStyle settingsDetailStyle(BuildContext context) => TextStyle(
  color: settingsInk(context).withValues(alpha: 0.65),
  fontSize: 13,
);

/// A settings screen: a back button and [title] over the ambient canvas,
/// then [children] (usually [SettingsSection]s) in a list.
class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: AmbientCanvas(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          Space.gutter,
          MediaQuery.paddingOf(context).top + Space.s,
          Space.gutter,
          MediaQuery.paddingOf(context).bottom + Space.gutter,
        ),
        children: <Widget>[
          Row(
            children: <Widget>[
              GlassIconButton(
                icon: Icons.chevron_left_rounded,
                label: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: settingsInk(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.l),
          ...children,
        ],
      ),
    ),
  );
}

/// A group of settings rows on one glass panel, with an optional heading.
class SettingsSection extends StatelessWidget {
  const SettingsSection({required this.children, this.heading, super.key});

  final String? heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.m),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (heading != null)
          Padding(
            padding: const EdgeInsets.only(left: Space.xs, bottom: Space.xs),
            child: Semantics(
              header: true,
              child: Text(
                heading!.toUpperCase(),
                style: settingsDetailStyle(context)
                    .copyWith(fontSize: 12, letterSpacing: 0.4),
              ),
            ),
          ),
        GlassSurface(
          padding: const EdgeInsets.symmetric(vertical: Space.xxs),
          child: Column(children: children),
        ),
      ],
    ),
  );
}
