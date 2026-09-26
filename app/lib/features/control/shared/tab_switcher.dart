import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../design/tokens/tokens.dart';

/// The tab body: a new panel fades in while sliding 12 px in the direction
/// of travel (left towards a later tab) on a [Motion.snappy] spring, the old
/// one fading and sliding out; the height glides so the page doesn't jump.
/// Under Reduce Motion the panel is simply swapped.
class TabSwitcher extends StatefulWidget {
  const TabSwitcher({required this.index, required this.child, super.key});

  /// Position of the tab shown (sets the direction of travel).
  final int index;

  /// The panel, keyed by its tab.
  final Widget child;

  @override
  State<TabSwitcher> createState() => TabSwitcherState();
}

class TabSwitcherState extends State<TabSwitcher>
    with SingleTickerProviderStateMixin {
  static const double _slide = 12;

  /// Progress of the switch; 1 = the new panel is in place.
  late final AnimationController _t = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  Widget? _out;
  double _dir = 1;
  int _switches = 0;

  @override
  void didUpdateWidget(TabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child.key == oldWidget.child.key) return;
    if (Motion.reduced(context)) {
      _t.stop();
      _t.value = 1;
      _out = null;
      return;
    }
    _out = oldWidget.child;
    _dir = widget.index >= oldWidget.index ? 1 : -1;
    final int switchNo = ++_switches;
    _t.value = 0;
    _t
        .animateWith(
          // Done once the rest is invisible (0.06 px, 0.5 % opacity), so the
          // two panels overlap for as few frames as possible.
          SpringSimulation(
            Motion.snappy,
            0,
            1,
            0,
            tolerance: const Tolerance(distance: 0.005, velocity: 0.05),
          ),
        )
        .whenCompleteOrCancel(() {
          // Only the latest switch clears its outgoing panel.
          if (mounted && switchNo == _switches) setState(() => _out = null);
        });
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget panels = AnimatedBuilder(
      animation: _t,
      builder: (BuildContext context, _) {
        final double t = _t.value.clamp(0.0, 1.0);
        final Widget? out = _out;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // The old panel on top of the list's flow, so the height
            // follows the new one.
            if (out != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 1 - t,
                    child: Transform.translate(
                      offset: Offset(-_dir * _slide * t, 0),
                      child: out,
                    ),
                  ),
                ),
              ),
            Opacity(
              opacity: out == null ? 1 : t,
              child: Transform.translate(
                offset: Offset(out == null ? 0 : _dir * _slide * (1 - t), 0),
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
    // Reduce Motion: no height glide either (a zero-length AnimatedSize
    // would finish inside its own layout).
    if (Motion.reduced(context)) return panels;
    return AnimatedSize(
      duration: Motion.medium,
      curve: Motion.emphasized,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.none,
      child: panels,
    );
  }
}
