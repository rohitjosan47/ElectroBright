import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/fixture.dart';
import '../../core/model/light_capabilities.dart';
import '../../design/canvas/ambient_canvas.dart';
import '../../design/components/fixture_type.dart';
import '../../design/components/glass_controls.dart';
import '../../design/glass/glass_surface.dart';
import '../../design/haptics/haptics.dart';
import '../../design/haptics/haptics_scope.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tone/tone_scope.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../l10n/app_localizations.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/fixture_session.dart';
import '../../sessions/rituals.dart';
import '../firmware_update/firmware_update_screen.dart';

enum _Step { pick, connecting, found, failed }

/// Adding a light: pick it from the nearby list, connect and identify it
/// (its firmware says what type it is), flash it to be sure, name it, save.
/// Nothing is saved until Save; Cancel always releases the light.
class AddLightScreen extends ConsumerStatefulWidget {
  const AddLightScreen({this.initial, super.key});

  /// Start connecting to this nearby light right away.
  final NearbyLight? initial;

  @override
  ConsumerState<AddLightScreen> createState() => _AddLightScreenState();
}

class _AddLightScreenState extends ConsumerState<AddLightScreen> {
  _Step _step = _Step.pick;
  NearbyLight? _picked;
  String? _candidateId;
  Want? _want;
  StreamSubscription<FixtureStatus>? _sub;
  Timer? _timeout;
  EbFirmware? _firmware;
  bool _identifying = false;
  bool _saved = false;
  final TextEditingController _name = TextEditingController();

  AppSession get _app => ref.read(appSessionProvider)!;

  @override
  void initState() {
    super.initState();
    final NearbyLight? n = widget.initial;
    if (n != null) scheduleMicrotask(() => _pick(n));
  }

  @override
  void dispose() {
    unawaited(_release());
    _name.dispose();
    super.dispose();
  }

  Future<void> _release() async {
    _timeout?.cancel();
    await _sub?.cancel();
    _sub = null;
    _want?.release();
    _want = null;
    final String? id = _candidateId;
    _candidateId = null;
    if (id != null && !_saved) await _app.ble.connections.unregister(id);
  }

  void _pick(NearbyLight n) {
    if (n.isLegacy) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FirmwareUpdateScreen(
              name: n.seen.name,
              incompatibility: EbIncompatibility.legacyFirmware,
            ),
          ),
        ),
      );
      return;
    }
    final String id = newFixtureId();
    // The final id is used from the start, so Save keeps this connection.
    final Fixture candidate = Fixture(
      id: id,
      deviceId: n.seen.id,
      name: n.seen.name,
      layout: n.layoutHint ?? ChannelLayout.rgbw,
      driver: DriverKind.electroBright,
      addedAt: DateTime.now(),
    );
    final ConnectionManager cm = _app.ble.connections;
    cm.register(candidate);
    _candidateId = id;
    _picked = n;
    _want = cm.want(id, WantReason.screen);
    setState(() => _step = _Step.connecting);
    _timeout = Timer(const Duration(seconds: 20), () {
      if (mounted && _step == _Step.connecting) {
        setState(() => _step = _Step.failed);
      }
    });
    _sub = cm.session(id)!.statuses.listen(_onStatus);
  }

  void _onStatus(FixtureStatus st) {
    if (!mounted || _step != _Step.connecting) return;
    if (st.phase == LinkPhase.ready && st.view?.firmware != null) {
      _timeout?.cancel();
      final EbFirmware fw = st.view!.firmware!;
      HapticsScope.of(context).play(HapticEvent.connected);
      setState(() {
        _firmware = fw;
        _step = _Step.found;
        _name.text = fixtureTypeDescription(
          AppLocalizations.of(context),
          fw.layout,
        );
      });
    } else if (st.phase == LinkPhase.incompatible) {
      _timeout?.cancel();
      final String name = _picked?.seen.name ?? '';
      unawaited(_release());
      setState(() => _step = _Step.pick);
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FirmwareUpdateScreen(
              name: name,
              incompatibility: st.incompatibility,
              detail: st.detail,
            ),
          ),
        ),
      );
    }
  }

  Future<void> _identify() async {
    final String? id = _candidateId;
    final FixtureSession? s = id == null
        ? null
        : _app.ble.connections.session(id);
    if (s?.session == null) return;
    setState(() => _identifying = true);
    await s!.identify();
    if (mounted) setState(() => _identifying = false);
  }

  void _save() {
    final String? id = _candidateId;
    final EbFirmware? fw = _firmware;
    final NearbyLight? n = _picked;
    if (id == null || fw == null || n == null) return;
    final String name = _name.text.trim().isEmpty
        ? fixtureTypeDescription(AppLocalizations.of(context), fw.layout)
        : _name.text.trim();
    _saved = true;
    _app.registry.add(
      Fixture(
        id: id,
        deviceId: n.seen.id,
        name: name,
        layout: fw.layout,
        driver: DriverKind.electroBright,
        addedAt: DateTime.now(),
        identity: FixtureIdentity(
          capabilities: fw.capabilities,
          model: fw.model,
          firmwareVersion: fw.version.version,
          learnedAt: DateTime.now(),
        ),
        lastConnectedAt: DateTime.now(),
      ),
    );
    HapticsScope.of(context).play(HapticEvent.success);
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientCanvas(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: Space.s),
                Row(
                  children: <Widget>[
                    GlassIconButton(
                      icon: Icons.close_rounded,
                      label: l.cancel,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: Space.s),
                    Text(
                      l.addTitle,
                      style: TextStyle(
                        color: fg,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.l),
                Expanded(
                  child: switch (_step) {
                    _Step.pick => _PickList(onPick: _pick),
                    _Step.connecting => _Busy(text: l.addConnecting),
                    _Step.failed => _Failed(
                      onRetry: () async {
                        await _release();
                        if (mounted) setState(() => _step = _Step.pick);
                      },
                    ),
                    _Step.found => _Found(
                      firmware: _firmware!,
                      name: _name,
                      identifying: _identifying,
                      onIdentify: _identify,
                      onSave: _save,
                    ),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickList extends ConsumerWidget {
  const _PickList({required this.onPick});
  final ValueChanged<NearbyLight> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<NearbyLight> nearby = ref.watch(nearbyProvider);
    final List<Fixture> saved = ref.watch(fixturesProvider);
    final bool dark = ToneScope.of(context).dark;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    return ListView(
      children: <Widget>[
        Text(l.addHint, style: TextStyle(color: fg.withValues(alpha: 0.7))),
        const SizedBox(height: Space.m),
        if (nearby.isEmpty) _Busy(text: l.addSearching),
        for (final NearbyLight n in nearby)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: NearbyRow(
              light: n,
              already: saved
                  .where((Fixture f) => f.deviceId == n.seen.id)
                  .firstOrNull
                  ?.name,
              onTap: () => onPick(n),
            ),
          ),
      ],
    );
  }
}

/// A nearby, not yet added light: its type (from the advertised name),
/// signal and an Add action.
class NearbyRow extends StatelessWidget {
  const NearbyRow({
    required this.light,
    required this.onTap,
    this.already,
    super.key,
  });
  final NearbyLight light;
  final VoidCallback onTap;
  final String? already;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.of(context).dark;
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final ChannelLayout? hint = light.layoutHint;
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: already == null ? onTap : null,
        child: GlassSurface(
          radius: Radii.medium,
          padding: const EdgeInsets.all(Space.m),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.lightbulb_outline_rounded,
                color: fg.withValues(alpha: 0.8),
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      hint == null
                          ? l.nearbyUnknownType
                          : '${fixtureTypeName(l, hint)} · ${fixtureTypeDescription(l, hint)}',
                      style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      already != null
                          ? l.addAlready(already!)
                          : light.isLegacy
                          ? l.nearbyUpdate
                          : light.seen.name,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (hint != null) ChannelDots(layout: hint),
              const SizedBox(width: Space.s),
              _Bars(bars: light.seen.signalBars, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars({required this.bars, required this.color});
  final int bars;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: <Widget>[
      for (int i = 0; i < 4; i++)
        Container(
          width: 3,
          height: 5.0 + i * 3,
          margin: const EdgeInsets.only(left: 2),
          color: color.withValues(alpha: i < bars ? 0.8 : 0.2),
        ),
    ],
  );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xl),
    child: Column(
      children: <Widget>[
        const CircularProgressIndicator.adaptive(),
        const SizedBox(height: Space.m),
        Text(text, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return Column(
      children: <Widget>[
        Text(l.addFailed, textAlign: TextAlign.center),
        const SizedBox(height: Space.m),
        FilledButton(onPressed: onRetry, child: Text(l.tryAgain)),
      ],
    );
  }
}

class _Found extends StatelessWidget {
  const _Found({
    required this.firmware,
    required this.name,
    required this.identifying,
    required this.onIdentify,
    required this.onSave,
  });
  final EbFirmware firmware;
  final TextEditingController name;
  final bool identifying;
  final VoidCallback onIdentify;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final LightCapabilities caps = firmware.capabilities;
    return ListView(
      children: <Widget>[
        GlassSurface(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FixtureTypeBadge(layout: caps.layout),
              const SizedBox(height: Space.s),
              Text(
                l.addFound(
                  fixtureTypeDescription(l, caps.layout),
                  firmware.version.version,
                ),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Space.m),
              OutlinedButton.icon(
                onPressed: identifying ? null : onIdentify,
                icon: const Icon(Icons.flare_rounded),
                label: Text(l.addIdentify),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.l),
        TextField(
          controller: name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: l.addName),
          onSubmitted: (_) => onSave(),
        ),
        const SizedBox(height: Space.l),
        FilledButton(onPressed: onSave, child: Text(l.addSave)),
      ],
    );
  }
}
