import 'package:flutter/material.dart';

import '../../design/components/glass_controls.dart';

/// What a light's (or a group's) screen shows once what it shows is gone
/// while it is open: an empty page for one frame, then back to Home with
/// [message].
class RemovedScreen extends StatefulWidget {
  const RemovedScreen({required this.message, super.key});

  final String message;

  @override
  State<RemovedScreen> createState() => _RemovedScreenState();
}

class _RemovedScreenState extends State<RemovedScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      // Only a screen still on the stack closes: one already leaving (after
      // Forget, say) stays quiet, and the first to close takes every other
      // open screen with it, so the message shows once.
      if (route == null || !route.isActive || route.isFirst) return;
      showGlassToast(context, widget.message, icon: Icons.info_outline_rounded);
      Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
