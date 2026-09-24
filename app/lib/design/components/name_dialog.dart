import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../tokens/tokens.dart';

/// Asks for a name (null = cancelled), optionally with suggestion chips.
Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  String? current,
  List<String> suggestions = const <String>[],
}) => showDialog<String>(
  context: context,
  builder: (BuildContext ctx) =>
      _NameDialog(title: title, current: current, suggestions: suggestions),
);

/// Owns its text controller: it must outlive the dialog's exit animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.current,
    required this.suggestions,
  });
  final String title;
  final String? current;
  final List<String> suggestions;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _c,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (String v) => Navigator.pop(context, v.trim()),
            ),
            if (widget.suggestions.isNotEmpty) ...<Widget>[
              const SizedBox(height: Space.s),
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: <Widget>[
                  for (final String s in widget.suggestions)
                    ActionChip(label: Text(s), onPressed: () => _c.text = s),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: Text(l.addSave),
        ),
      ],
    );
  }
}
