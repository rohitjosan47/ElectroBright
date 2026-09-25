import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../bootstrap/service_registry.dart';
import '../../core/model/fixture.dart';
import '../../core/model/channel_color.dart';
import '../../core/model/channel_layout.dart';
import '../../core/model/light_capabilities.dart';
import '../../core/protocol/eb/eb_fixture_catalog.dart';
import '../../design/platform/platform_bridge.dart';
import '../../drivers/electrobright/eb_session.dart';
import '../../drivers/electrobright/eb_types.dart';
import '../../sessions/connection_manager.dart';
import '../../sessions/discovery.dart';
import '../../sessions/fixture_session.dart';

/// Hardware test bench (M2 gate): connect to a real light and run the
/// connection, streaming, timer and resync checks on the phone.
class BleLabScreen extends ConsumerStatefulWidget {
  const BleLabScreen({super.key});

  @override
  ConsumerState<BleLabScreen> createState() => _BleLabScreenState();
}

class _BleLabScreenState extends ConsumerState<BleLabScreen> {
  BleStack? _ble;
  ScanLease? _lease;
  StreamSubscription<SeenDevice>? _seenSub;
  StreamSubscription<FixtureStatus>? _statusSub;
  final List<SeenDevice> _found = <SeenDevice>[];
  FixtureSession? _session;
  Want? _want;
  FixtureStatus? _status;
  final List<String> _log = <String>[];
  bool _busy = false;
  String _auth = '?';

  AppServices get _services => ref.read(servicesProvider);

  @override
  void dispose() {
    unawaited(_seenSub?.cancel());
    unawaited(_statusSub?.cancel());
    _lease?.release();
    _want?.release();
    super.dispose();
  }

  void _say(String s) {
    setState(
      () => _log.insert(
        0,
        '${DateTime.now().toIso8601String().substring(11, 19)}  $s',
      ),
    );
  }

  Future<void> _start({required bool demo}) async {
    if (!demo) {
      BluetoothAuthorization a = await _services.platform.authorization();
      if (a == BluetoothAuthorization.notDetermined) {
        a = await _services.platform.requestAuthorization();
      }
      setState(() => _auth = a.name);
      if (a != BluetoothAuthorization.allowed) {
        _say('Bluetooth not allowed ($a)');
        return;
      }
    }
    final BleStack ble = await _services.startBle(demo: demo);
    await _seenSub?.cancel();
    _lease?.release();
    setState(() {
      _ble = ble;
      _found.clear();
    });
    _lease = ble.discovery.acquire(ScanNeed.panel);
    _seenSub = ble.discovery.updates.listen((SeenDevice d) {
      if (d.deviceClass == DeviceClass.other) return;
      setState(() {
        _found.removeWhere((SeenDevice x) => x.id == d.id);
        _found.add(d);
      });
    });
    _say(demo ? 'Demo lights started' : 'Scanning');
  }

  Future<void> _connect(SeenDevice d) async {
    final BleStack ble = _ble!;
    _want?.release();
    await _statusSub?.cancel();
    // A hint from the advertised name; the handshake confirms it.
    final ChannelLayout hint =
        EbFixtureCatalog.layoutFromBleName(d.name) ?? ChannelLayout.rgbw;
    final Fixture f = Fixture(
      id: 'lab-${d.id}',
      deviceId: d.id,
      name: d.name,
      layout: hint,
      driver: DriverKind.electroBright,
      addedAt: DateTime.now(),
      whitePoints: EbFixtureCatalog.whitePointsFor(layout: hint),
    );
    ble.connections.register(f);
    final FixtureSession s = ble.connections.session(f.id)!;
    _statusSub = s.statuses.listen(
      (FixtureStatus st) => setState(() => _status = st),
    );
    final Stopwatch sw = Stopwatch()..start();
    _want = ble.connections.want(f.id, WantReason.screen);
    setState(() {
      _session = s;
      _status = s.status;
    });
    final FixtureStatus ready = await s.statuses
        .firstWhere(
          (FixtureStatus x) => x.isReady || x.phase == LinkPhase.incompatible,
        )
        .timeout(const Duration(seconds: 20), onTimeout: () => s.status);
    _say('${ready.phase.name} in ${sw.elapsedMilliseconds} ms');
  }

  /// The next mode this light supports (e.g. W skips Rainbow).
  int _nextMode(EbView v) {
    final LightCapabilities caps =
        v.firmware?.capabilities ??
        LightCapabilities.assumed(_eb?.layout ?? ChannelLayout.rgbw);
    final List<int> modes = caps.modes;
    final int at = modes.indexOf(v.state.scene.mode);
    return modes[(at + 1) % modes.length];
  }

  EbSession? get _eb => _session?.session;

  Future<void> _run(String name, Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    _say('▶ $name');
    try {
      await body();
    } on Object catch (e) {
      _say('✖ $name: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _streamTest() => _run('Stream 40 Hz × 10 s', () async {
    final EbSession s = _eb!;
    final Map<String, int>? before = await s.diag();
    s.beginGesture(EbKeys.color);
    final ChannelLayout layout = s.layout;
    ChannelColor last = ChannelColor.black(layout);
    for (int i = 0; i < 400; i++) {
      final double h = i / 400 * 2 * pi;
      last = ChannelColor(layout, <int>[
        for (int c = 0; c < layout.n; c++)
          (127 + 127 * sin(h + c * 2.1)).round(),
      ]);
      s.setColor(last, live: true);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    s.endGesture(EbKeys.color);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await s.resync();
    final Map<String, int>? after = await s.diag();
    final bool ok = s.confirmed.scene.color == last;
    _say(
      '${ok ? '✔' : '✖'} final colour ${ok ? 'matches' : 'MISMATCH'}; '
      'binbad +${(after?['binbad'] ?? 0) - (before?['binbad'] ?? 0)}, '
      'sdrop +${(after?['sdrop'] ?? 0) - (before?['sdrop'] ?? 0)}, '
      'frames ${s.streamLane.framesWritten}, divergences ${s.divergences}',
    );
  });

  Future<void> _cycleTest() => _run('100 connect/disconnect cycles', () async {
    final FixtureSession s = _session!;
    int ok = 0;
    final List<int> times = <int>[];
    for (int i = 0; i < 100; i++) {
      final Future<FixtureStatus> down = s.statuses
          .firstWhere((FixtureStatus x) => !x.isReady)
          .timeout(const Duration(seconds: 5), onTimeout: () => s.status);
      await _ble!.connections.reconnect(s.fixture.id);
      await down;
      final Stopwatch sw = Stopwatch()..start();
      final FixtureStatus st = await s.statuses
          .firstWhere((FixtureStatus x) => x.isReady)
          .timeout(const Duration(seconds: 15), onTimeout: () => s.status);
      if (st.isReady) {
        ok++;
        times.add(sw.elapsedMilliseconds);
      }
      if (i % 10 == 9) _say('  $ok/${i + 1} connected');
    }
    times.sort();
    final int under2s = times.where((int t) => t < 2000).length;
    _say(
      '${ok == 100 ? '✔' : '✖'} $ok/100 connected; $under2s under 2 s; '
      'median ${times.isEmpty ? '-' : times[times.length ~/ 2]} ms',
    );
  });

  Future<void> _timerTest() => _run('Timer push (3 s)', () async {
    final EbSession s = _eb!;
    await s.setPower(on: true);
    final Future<EbEvent> expired = s.events
        .firstWhere((EbEvent e) => e is EbTimerExpired)
        .timeout(const Duration(seconds: 8));
    await s.setTimer(3);
    await expired;
    _say(
      s.view.state.sleeping ? '✔ light slept and reported it' : '✖ state wrong',
    );
    await s.setPower(on: true);
  });

  Future<void> _backgroundTest() => _run('Resync (as after resume)', () async {
    final EbSession s = _eb!;
    await s.onResume();
    _say(
      '✔ resync done; divergences ${s.divergences}, malformed ${s.malformedLines}',
    );
  });

  Future<void> _diag() => _run('DIAG', () async {
    final EbSession s = _eb!;
    final Duration? rtt = await s.ping();
    final Map<String, int>? d = await s.diag();
    _say(
      'PING ${rtt?.inMilliseconds} ms; MTU ${_ble!.connections.session(_session!.fixture.id)?.session != null ? 'ok' : '-'}',
    );
    _say('DIAG $d');
  });

  Future<void> _export() async {
    await Clipboard.setData(ClipboardData(text: _services.trace.export()));
    _say('Trace (${_services.trace.entries.length} lines) copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final FixtureStatus? st = _status;
    final EbView? v = st?.view;
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Lab')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: () => _start(demo: false),
                child: const Text('Scan real lights'),
              ),
              OutlinedButton(
                onPressed: () => _start(demo: true),
                child: const Text('Demo lights'),
              ),
            ],
          ),
          Text('Bluetooth permission: $_auth'),
          const Divider(),
          for (final SeenDevice d in _found)
            ListTile(
              title: Text(d.name.isEmpty ? d.id : d.name),
              subtitle: Text('${d.deviceClass.name} · ${d.rssi} dBm · ${d.id}'),
              trailing: const Icon(Icons.link),
              onTap: () => _connect(d),
            ),
          if (st != null) ...<Widget>[
            const Divider(),
            Text(
              'Phase: ${st.phase.name}${st.detail == null ? '' : ' (${st.detail})'}'
              '${st.legacyFirmware ? ' — firmware update needed' : ''}',
            ),
            if (v != null) ...<Widget>[
              Text(
                'Firmware ${v.firmware?.version.version} · ${v.firmware?.model}',
              ),
              Text(
                'Mode ${v.state.scene.mode} · colour ${v.state.scene.color} · '
                'brightness ${v.state.scene.brightness} · ${v.state.sleeping ? 'off' : 'on'}',
              ),
              Text('Pending: ${v.pending.join(', ')}'),
              Slider(
                value: v.state.scene.brightness.toDouble(),
                max: 255,
                onChangeStart: (_) => _session!.beginGesture(EbKeys.brightness),
                onChanged: (double x) =>
                    _session!.setBrightness(x.round(), live: true),
                onChangeEnd: (_) => _session!.endGesture(EbKeys.brightness),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.tonal(
                    onPressed: _busy ? null : _streamTest,
                    child: const Text('Stream test'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _cycleTest,
                    child: const Text('100 cycles'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _timerTest,
                    child: const Text('Timer push'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _backgroundTest,
                    child: const Text('Resync'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _diag,
                    child: const Text('PING + DIAG'),
                  ),
                  OutlinedButton(
                    onPressed: () => _session!.setPower(on: v.state.sleeping),
                    child: Text(v.state.sleeping ? 'Power on' : 'Power off'),
                  ),
                  OutlinedButton(
                    onPressed: () => _session!.setMode(_nextMode(v)),
                    child: const Text('Next mode'),
                  ),
                ],
              ),
            ],
          ],
          const Divider(),
          Row(
            children: <Widget>[
              const Expanded(child: Text('Log')),
              TextButton(onPressed: _export, child: const Text('Copy trace')),
            ],
          ),
          for (final String l in _log.take(200))
            Text(l, style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
        ],
      ),
    );
  }
}
