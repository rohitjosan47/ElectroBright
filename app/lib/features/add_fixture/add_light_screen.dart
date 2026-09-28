import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_session.dart';
import '../../app/providers.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/fixture.dart';
import '../../core/model/light_capabilities.dart';
import '../../core/protocol/eb/eb_fixture_catalog.dart';
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

/// How long the add flow waits for a picked light before saying it failed.
const Duration connectLimit = Duration(seconds: 20);

/// [base], or "[base] 2", "[base] 3"... : the first not in [taken].
String uniqueLightName(String base, Iterable<String> taken) {
  final Set<String> used = taken.toSet();
  if (!used.contains(base)) return base;
  for (int n = 2; ; n++) {
    final String name = '$base $n';
    if (!used.contains(name)) return name;
  }
}

/// Adding a light: pick it from the nearby list, connect and identify it
/// (its firmware says what type it is), flash it to be sure, name it, save.
/// Nothing is saved until Save; Cancel always releases the light.
class AddLightScreen extends ConsumerStatefulWidget {
  const AddLightScreen({super.key});

  @override
  ConsumerState<AddLightScreen> createState() => _AddLightScreenState();
}

class _AddLightScreenState extends ConsumerState<AddLightScreen> {
  _Step _step = _Step.pick;
  NearbyLight? _picked;
  String? _candidateId;
  Want? _want;

  /// The manager holding the candidate, kept so [dispose] never uses `ref`
  /// (unsafe while unmounting: the candidate would stay connected).
  ConnectionManager? _connections;
  StreamSubscription<FixtureStatus>? _sub;
  Timer? _timeout;
  EbFirmware? _firmware;

  /// The light has no fixture type yet (setup-needed mode): it is saved as
  /// such and set up from Home.
  bool _setupNeeded = false;
  bool _identifying = false;
  bool _saved = false;
  final TextEditingController _name = TextEditingController();

  AppSession get _app => ref.read(appSessionProvider)!;

  @override
  void dispose() {
    unawaited(_release());
    _name.dispose();
    super.dispose();
  }

  /// Drops the candidate. Everything up to the unregister happens at once
  /// (no await before it), so a light picked again right after never finds
  /// this one still holding it; the returned future ends once its link is
  /// closed.
  Future<void> _release() {
    _timeout?.cancel();
    _timeout = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _want?.release();
    _want = null;
    final String? id = _candidateId;
    final ConnectionManager? cm = _connections;
    _candidateId = null;
    if (id == null || cm == null || _saved) return Future<void>.value();
    return cm.unregister(id);
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
      whitePoints: EbFixtureCatalog.whitePointsFor(
        layout: n.layoutHint ?? ChannelLayout.rgbw,
      ),
    );
    final ConnectionManager cm = _app.ble.connections;
    // A candidate this screen still holds (Retry) goes first.
    unawaited(_release());
    cm.register(candidate);
    _connections = cm;
    _candidateId = id;
    _picked = n;
    setState(() => _step = _Step.connecting);
    // Found or failed within [connectLimit], whatever the radio does.
    _timeout = Timer(connectLimit, () {
      if (mounted && _step == _Step.connecting) {
        setState(() => _step = _Step.failed);
      }
    });
    // Listen before asking to connect, then read where it is now: a ready
    // that comes at once is never missed.
    final FixtureSession session = cm.session(id)!;
    _sub = session.statuses.listen(_onStatus);
    _want = cm.want(id, WantReason.screen);
    _onStatus(session.status);
  }

  void _onStatus(FixtureStatus st) {
    if (!mounted || _step != _Step.connecting) return;
    if (st.phase == LinkPhase.ready && st.view?.firmware != null) {
      _timeout?.cancel();
      final EbFirmware fw = st.view!.firmware!;
      HapticsScope.of(context).play(HapticEvent.connected);
      setState(() {
        _firmware = fw;
        _setupNeeded = false;
        _step = _Step.found;
        _name.text = _defaultName(fw.layout);
      });
    } else if (st.phase == LinkPhase.incompatible &&
        st.incompatibility == EbIncompatibility.setupNeeded) {
      _timeout?.cancel();
      HapticsScope.of(context).play(HapticEvent.connected);
      setState(() {
        _firmware = null;
        _setupNeeded = true;
        _step = _Step.found;
        _name.text = _newName();
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

  /// The type's name ("RGBW light"), numbered to be unique among the saved
  /// lights (every light of a type advertises the same BLE name).
  String _defaultName(ChannelLayout layout) {
    final AppLocalizations l = AppLocalizations.of(context);
    return uniqueLightName(
      l.defaultLightName(fixtureTypeName(l, layout)),
      _app.registry.fixtures.map((Fixture f) => f.name),
    );
  }

  /// "New light", numbered to be unique (a light without a type).
  String _newName() => uniqueLightName(
    AppLocalizations.of(context).newLightName,
    _app.registry.fixtures.map((Fixture f) => f.name),
  );

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
    if (id == null || n == null) return;
    if (fw == null) {
      if (_setupNeeded) _saveSetupNeeded(id, n);
      return;
    }
    final String name = _name.text.trim().isEmpty
        ? _defaultName(fw.layout)
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
        // The handshake already named the model.
        whitePoints: EbFixtureCatalog.whitePointsFor(
          modelId: fw.model,
          layout: fw.layout,
        ),
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

  void _saveSetupNeeded(String id, NearbyLight n) {
    final ChannelLayout guess = n.layoutHint ?? ChannelLayout.rgbw;
    _saved = true;
    _app.registry.add(
      Fixture(
        id: id,
        deviceId: n.seen.id,
        name: _name.text.trim().isEmpty ? _newName() : _name.text.trim(),
        layout: guess,
        driver: DriverKind.electroBright,
        addedAt: DateTime.now(),
        whitePoints: EbFixtureCatalog.whitePointsFor(layout: guess),
        setupNeeded: true,
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
                      firmware: _firmware,
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

/// The nearby lights to pick from (strongest first; "Not mine" hides one),
/// then the lights on unsupported firmware, then a way back to the hidden
/// ones.
class _PickList extends ConsumerWidget {
  const _PickList({required this.onPick});
  final ValueChanged<NearbyLight> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<NearbyLight> nearby = ref.watch(nearbyProvider);
    final List<Fixture> saved = ref.watch(fixturesProvider);
    final Set<String> hidden = ref.watch(hiddenLightsProvider);
    final HiddenLightsNotifier hide = ref.read(hiddenLightsProvider.notifier);
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    final List<NearbyLight> lights = <NearbyLight>[
      for (final NearbyLight n in nearby)
        if (!n.isLegacy && !hidden.contains(n.seen.id)) n,
    ];
    // Older firmware the app can't drive: last, apart from the rest.
    final List<NearbyLight> unsupported = <NearbyLight>[
      for (final NearbyLight n in nearby)
        if (n.isLegacy) n,
    ];
    return ListView(
      children: <Widget>[
        Text(l.addHint, style: TextStyle(color: fg.withValues(alpha: 0.7))),
        const SizedBox(height: Space.m),
        if (lights.isEmpty) _Busy(text: l.addSearching),
        for (final NearbyLight n in lights)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: NearbyRow(
              light: n,
              already: saved
                  .where((Fixture f) => f.deviceId == n.seen.id)
                  .firstOrNull
                  ?.name,
              onTap: () => onPick(n),
              onHide: () => hide.hide(n.seen.id),
            ),
          ),
        if (unsupported.isNotEmpty) ...<Widget>[
          const SizedBox(height: Space.l - Space.s),
          Semantics(
            header: true,
            child: Text(
              l.unsupportedTitle,
              style: TextStyle(
                color: fg,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l.unsupportedNote,
            style: TextStyle(color: fg.withValues(alpha: 0.65)),
          ),
          const SizedBox(height: Space.s),
          for (final NearbyLight n in unsupported)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: NearbyRow(light: n, onTap: () => onPick(n)),
            ),
        ],
        if (hidden.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.s, bottom: Space.l),
            child: Center(
              child: TextButton.icon(
                key: const ValueKey<String>('show-hidden-lights'),
                onPressed: hide.showAll,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(l.showHiddenLights),
              ),
            ),
          ),
      ],
    );
  }
}

/// A nearby, not yet added light: its type (from the advertised name),
/// signal and, with [onHide], a "Not mine" action. A tap adds it.
class NearbyRow extends StatelessWidget {
  const NearbyRow({
    required this.light,
    required this.onTap,
    this.onHide,
    this.already,
    super.key,
  });
  final NearbyLight light;
  final VoidCallback onTap;

  /// "Not mine": hides the light (see [hiddenLightsProvider]).
  final VoidCallback? onHide;
  final String? already;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.darkOf(context);
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
              // "Not mine" under the type and signal, so the name keeps
              // its width.
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (hint != null) ChannelDots(layout: hint),
                      const SizedBox(width: Space.s),
                      _Bars(bars: light.seen.signalBars, color: fg),
                    ],
                  ),
                  if (onHide != null)
                    TextButton(
                      key: ValueKey<String>('not-mine-${light.seen.id}'),
                      onPressed: onHide,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.s,
                        ),
                        foregroundColor: fg.withValues(alpha: 0.75),
                      ),
                      child: Text(l.notMine),
                    ),
                ],
              ),
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

  /// Null for a light without a fixture type yet (setup-needed mode).
  final EbFirmware? firmware;
  final TextEditingController name;
  final bool identifying;
  final VoidCallback onIdentify;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final EbFirmware? fw = firmware;
    final LightCapabilities? caps = fw?.capabilities;
    return ListView(
      children: <Widget>[
        GlassSurface(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (caps == null)
                const SetupNeededBadge()
              else
                FixtureTypeBadge(layout: caps.layout),
              const SizedBox(height: Space.s),
              Text(
                caps == null
                    ? l.addFoundSetup
                    : l.addFound(
                        fixtureTypeDescription(l, caps.layout),
                        fw!.version.version,
                      ),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (caps != null) ...<Widget>[
                const SizedBox(height: Space.m),
                OutlinedButton.icon(
                  onPressed: identifying ? null : onIdentify,
                  icon: const Icon(Icons.flare_rounded),
                  label: Text(l.addIdentify),
                ),
              ],
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
