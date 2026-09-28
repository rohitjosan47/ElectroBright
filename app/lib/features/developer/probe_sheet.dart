import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/color/led_white_points.dart';
import '../../core/model/channel_layout.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/settings_list.dart';
import '../../design/tokens/tokens.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/fixture_session.dart';
import 'fixture_probe.dart';

/// "Find the right type": lights each board output in turn (PROBE) and asks
/// whether it lights up, then suggests the fixture type those outputs make.
/// Returns the type the user chose to use, or null.
Future<ChannelLayout?> showProbeSheet(
  BuildContext context,
  FixtureSession session,
) => showModalBottomSheet<ChannelLayout>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext ctx) => ProbeFlow(session: session),
);

/// Name of a board output.
String probeOutputName(AppLocalizations l, ProbeOutput o) => switch (o) {
  ProbeOutput.red => l.channelR,
  ProbeOutput.green => l.channelG,
  ProbeOutput.blue => l.channelB,
  ProbeOutput.white => l.probeOutputWhite,
  ProbeOutput.warm => l.channelWw,
};

/// Screen colour of a board output's LED.
Color probeOutputColor(ProbeOutput o) => ledColor(switch (o) {
  ProbeOutput.red => ChannelRole.r,
  ProbeOutput.green => ChannelRole.g,
  ProbeOutput.blue => ChannelRole.b,
  ProbeOutput.white => ChannelRole.w,
  ProbeOutput.warm => ChannelRole.ww,
}, const LedWhitePoints());

enum _Probe { sending, asking, noAnswer, result }

/// The steps of the probe test (see [showProbeSheet]).
class ProbeFlow extends StatefulWidget {
  const ProbeFlow({required this.session, super.key});
  final FixtureSession session;

  @override
  State<ProbeFlow> createState() => _ProbeFlowState();
}

class _ProbeFlowState extends State<ProbeFlow> {
  int _step = 0;
  _Probe _phase = _Probe.sending;
  final Set<ProbeOutput> _lit = <ProbeOutput>{};

  /// The output the light may still be showing (it ends by itself after
  /// 3 s; ended early when the test moves on or closes).
  ProbeOutput? _on;

  ProbeOutput get _output => ProbeOutput.values[_step];

  @override
  void initState() {
    super.initState();
    unawaited(_light());
  }

  @override
  void dispose() {
    final ProbeOutput? on = _on;
    if (on != null) unawaited(widget.session.probe(on.index, on: false));
    super.dispose();
  }

  /// Lights the current output (again, for Retry).
  Future<void> _light() async {
    setState(() => _phase = _Probe.sending);
    final ProbeOutput o = _output;
    final EbResult r = await widget.session.probe(o.index, on: true);
    if (!mounted || o != _output) return;
    _on = r.isSuccess ? o : null;
    setState(() => _phase = r.isSuccess ? _Probe.asking : _Probe.noAnswer);
  }

  void _answer({required bool lit}) {
    if (lit) {
      _lit.add(_output);
    } else {
      _lit.remove(_output);
    }
    if (_step + 1 < ProbeOutput.values.length) {
      // The next PROBE replaces this one.
      setState(() => _step++);
      unawaited(_light());
      return;
    }
    final ProbeOutput? on = _on;
    _on = null;
    if (on != null) unawaited(widget.session.probe(on.index, on: false));
    setState(() => _phase = _Probe.result);
  }

  void _again() {
    _lit.clear();
    setState(() => _step = 0);
    unawaited(_light());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final TextStyle title = settingsTitleStyle(context)
        .copyWith(fontSize: 20, fontWeight: FontWeight.w700);
    final TextStyle detail = settingsDetailStyle(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          0,
          Space.gutter,
          Space.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l.findRightType, style: title),
            const SizedBox(height: Space.m),
            if (_phase == _Probe.result)
              ..._result(l, detail)
            else
              ..._question(l, detail),
          ],
        ),
      ),
    );
  }

  List<Widget> _question(AppLocalizations l, TextStyle detail) {
    final ProbeOutput o = _output;
    final String name = probeOutputName(l, o);
    final bool asking = _phase == _Probe.asking;
    return <Widget>[
      Text(l.probeStep(_step + 1, ProbeOutput.values.length), style: detail),
      const SizedBox(height: Space.s),
      Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: probeOutputColor(o),
              border: Border.all(
                color: settingsInk(context).withValues(alpha: 0.14),
              ),
            ),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text(
              name,
              key: const ValueKey<String>('probe-output'),
              style: settingsTitleStyle(context).copyWith(fontSize: 17),
            ),
          ),
          if (_phase == _Probe.sending)
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            ),
        ],
      ),
      const SizedBox(height: Space.s),
      Text(switch (_phase) {
        _Probe.noAnswer => l.probeNoAnswer,
        _Probe.sending => l.probeSending(name.toLowerCase()),
        _ => l.probeLit(name.toLowerCase()),
      }, style: detail),
      const SizedBox(height: Space.l),
      Text(l.probeQuestion, style: settingsTitleStyle(context)),
      const SizedBox(height: Space.s),
      Row(
        children: <Widget>[
          Expanded(
            child: FilledButton(
              key: const ValueKey<String>('probe-yes'),
              onPressed: asking ? () => _answer(lit: true) : null,
              child: Text(l.yes),
            ),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: FilledButton.tonal(
              key: const ValueKey<String>('probe-no'),
              onPressed: asking ? () => _answer(lit: false) : null,
              child: Text(l.no),
            ),
          ),
        ],
      ),
      const SizedBox(height: Space.xs),
      TextButton.icon(
        key: const ValueKey<String>('probe-retry'),
        onPressed: _phase == _Probe.sending ? null : () => unawaited(_light()),
        icon: const Icon(Icons.refresh_rounded),
        label: Text(l.retry),
      ),
    ];
  }

  List<Widget> _result(AppLocalizations l, TextStyle detail) {
    final ChannelLayout? type = suggestType(_lit);
    final String lit = <String>[
      for (final ProbeOutput o in ProbeOutput.values)
        if (_lit.contains(o)) probeOutputName(l, o),
    ].join(', ');
    return <Widget>[
      if (type != null) ...<Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: FixtureTypeBadge(layout: type),
        ),
        const SizedBox(height: Space.s),
        Text(
          l.probeSuggestion(fixtureTypeName(l, type)),
          key: const ValueKey<String>('probe-suggestion'),
          style: settingsTitleStyle(context).copyWith(fontSize: 17),
        ),
        const SizedBox(height: Space.xxs),
        Text(fixtureTypeDescription(l, type), style: detail),
      ] else
        Text(
          _lit.isEmpty ? l.probeNothingLit : l.probeNoMatch,
          key: const ValueKey<String>('probe-no-match'),
          style: settingsTitleStyle(context),
        ),
      if (_lit.isNotEmpty) ...<Widget>[
        const SizedBox(height: Space.xs),
        Text(l.probeLitList(lit), style: detail),
      ],
      const SizedBox(height: Space.l),
      if (type != null) ...<Widget>[
        FilledButton(
          key: const ValueKey<String>('probe-use'),
          onPressed: () => Navigator.of(context).pop(type),
          child: Text(l.probeUseType),
        ),
        const SizedBox(height: Space.xs),
      ],
      TextButton(
        key: const ValueKey<String>('probe-again'),
        onPressed: _again,
        child: Text(l.probeRunAgain),
      ),
    ];
  }
}
