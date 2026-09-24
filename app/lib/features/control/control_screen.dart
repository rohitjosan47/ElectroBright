import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/model/fixture.dart';

/// One light's controls (built from its capabilities).
class ControlScreen extends ConsumerWidget {
  const ControlScreen({required this.fixtureId, super.key});
  final String fixtureId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Fixture? f = ref.watch(fixtureProvider(fixtureId));
    return Scaffold(appBar: AppBar(title: Text(f?.name ?? '')));
  }
}
