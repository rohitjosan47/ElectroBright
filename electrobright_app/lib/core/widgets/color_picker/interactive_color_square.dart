import 'package:flutter/material.dart';

/// Standalone, high-precision 2D HSV Color Square with dedicated horizontal Hue slider.
///
/// Designed for dialogs and modal pickers (e.g. Police Dual Beacon customization).
/// Eliminates hue-collapse glitches by maintaining persistent internal HSV state.
class InteractiveColorSquare extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<bool>? onInteractionChanged;

  const InteractiveColorSquare({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
    this.onInteractionChanged,
  });

  @override
  State<InteractiveColorSquare> createState() => _InteractiveColorSquareState();
}

class _InteractiveColorSquareState extends State<InteractiveColorSquare> {
  late double _hue;
  late double _saturation;
  late double _value;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
  }

  @override
  void didUpdateWidget(covariant InteractiveColorSquare oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isDragging && oldWidget.initialColor != widget.initialColor) {
      if (widget.initialColor.value != _currentColor.value) {
        final hsv = HSVColor.fromColor(widget.initialColor);
        if (hsv.saturation > 0.05 && hsv.value > 0.05) {
          _hue = hsv.hue;
        }
        _saturation = hsv.saturation;
        _value = hsv.value;
      }
    }
  }

  Color get _currentColor =>
      HSVColor.fromAHSV(1.0, _hue, _saturation, _value).toColor();

  void _dispatchChange() {
    widget.onColorChanged(_currentColor);
  }

  void _handleSquarePan(Offset localPos, Size boxSize) {
    final s = (localPos.dx / boxSize.width).clamp(0.0, 1.0);
    final v = (1.0 - (localPos.dy / boxSize.height)).clamp(0.0, 1.0);
    setState(() {
      _saturation = s;
      _value = v;
    });
    _dispatchChange();
  }

  void _handleHuePan(Offset localPos, double trackWidth) {
    final fraction = (localPos.dx / trackWidth).clamp(0.0, 1.0);
    setState(() {
      _hue = (fraction * 360.0).clamp(0.0, 360.0);
    });
    _dispatchChange();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 2D Saturation / Value Gradient Box
        LayoutBuilder(
          builder: (context, constraints) {
            final boxWidth = constraints.maxWidth;
            final boxHeight = boxWidth * 0.65;

            return SizedBox(
              width: boxWidth,
              height: boxHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (details) {
                  _isDragging = true;
                  widget.onInteractionChanged?.call(true);
                  _handleSquarePan(details.localPosition, Size(boxWidth, boxHeight));
                },
                onPanUpdate: (details) {
                  _handleSquarePan(details.localPosition, Size(boxWidth, boxHeight));
                },
                onPanEnd: (_) {
                  _isDragging = false;
                  widget.onInteractionChanged?.call(false);
                },
                onPanCancel: () {
                  _isDragging = false;
                  widget.onInteractionChanged?.call(false);
                },
                child: CustomPaint(
                  size: Size(boxWidth, boxHeight),
                  painter: _SquarePainter(
                    hue: _hue,
                    saturation: _saturation,
                    value: _value,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),

        // Horizontal Rainbow Hue Slider
        LayoutBuilder(
          builder: (context, constraints) {
            final trackWidth = constraints.maxWidth;
            const trackHeight = 18.0;

            return SizedBox(
              width: trackWidth,
              height: trackHeight + 10,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (details) {
                  _isDragging = true;
                  widget.onInteractionChanged?.call(true);
                  _handleHuePan(details.localPosition, trackWidth);
                },
                onPanUpdate: (details) {
                  _handleHuePan(details.localPosition, trackWidth);
                },
                onPanEnd: (_) {
                  _isDragging = false;
                  widget.onInteractionChanged?.call(false);
                },
                onPanCancel: () {
                  _isDragging = false;
                  widget.onInteractionChanged?.call(false);
                },
                child: CustomPaint(
                  size: Size(trackWidth, trackHeight + 10),
                  painter: _HueBarPainter(hue: _hue),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SquarePainter extends CustomPainter {
  final double hue;
  final double saturation;
  final double value;

  const _SquarePainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));

    // Base fill: pure hue
    final pureHueColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
    canvas.drawRRect(rrect, Paint()..color = pureHueColor);

    // Horizontal White -> Transparent gradient
    final satShader = const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Colors.white, Color(0x00FFFFFF)],
    ).createShader(rect);
    canvas.drawRRect(rrect, Paint()..shader = satShader);

    // Vertical Transparent -> Black gradient
    final valShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x00000000), Colors.black],
    ).createShader(rect);
    canvas.drawRRect(rrect, Paint()..shader = valShader);

    // Border
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withOpacity(0.2),
    );

    // Thumb position
    final thumbX = saturation * size.width;
    final thumbY = (1.0 - value) * size.height;
    final thumbPos = Offset(thumbX, thumbY);

    final thumbColor = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();

    // Drop shadow
    canvas.drawCircle(
      thumbPos,
      12,
      Paint()
        ..color = Colors.black.withOpacity(0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // White outer ring
    canvas.drawCircle(
      thumbPos,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );

    // Dark inner accent
    canvas.drawCircle(
      thumbPos,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Colors.black.withOpacity(0.4),
    );

    // Color fill
    canvas.drawCircle(
      thumbPos,
      8,
      Paint()
        ..style = PaintingStyle.fill
        ..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(covariant _SquarePainter oldDelegate) {
    return oldDelegate.hue != hue ||
        oldDelegate.saturation != saturation ||
        oldDelegate.value != value;
  }
}

class _HueBarPainter extends CustomPainter {
  final double hue;

  const _HueBarPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final barRect = Rect.fromLTWH(0, 5, size.width, size.height - 10);
    final barRRect = RRect.fromRectAndRadius(barRect, const Radius.circular(8));

    // Rainbow gradient
    final rainbowShader = const LinearGradient(
      colors: [
        Color(0xFFFF0000),
        Color(0xFFFFFF00),
        Color(0xFF00FF00),
        Color(0xFF00FFFF),
        Color(0xFF0000FF),
        Color(0xFFFF00FF),
        Color(0xFFFF0000),
      ],
    ).createShader(barRect);

    canvas.drawRRect(barRRect, Paint()..shader = rainbowShader);

    // Border
    canvas.drawRRect(
      barRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Colors.white.withOpacity(0.2),
    );

    // Thumb position
    final thumbX = (hue / 360.0).clamp(0.0, 1.0) * size.width;
    final thumbPos = Offset(thumbX, size.height / 2);
    final thumbColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();

    canvas.drawCircle(
      thumbPos,
      10,
      Paint()
        ..color = Colors.black.withOpacity(0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    canvas.drawCircle(
      thumbPos,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );

    canvas.drawCircle(
      thumbPos,
      7,
      Paint()
        ..style = PaintingStyle.fill
        ..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(covariant _HueBarPainter oldDelegate) {
    return oldDelegate.hue != hue;
  }
}
