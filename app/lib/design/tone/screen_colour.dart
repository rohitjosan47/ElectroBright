import 'package:flutter/painting.dart';

import '../../core/color/color_science.dart';

/// [c] (linear light) as a screen colour, without rounding to 8 bits: a
/// colour that moves smoothly keeps moving smoothly until it is painted.
Color screenColour(LinearRgb c) => Color.from(
  alpha: 1,
  red: ColorScience.linearToSrgb(c.r),
  green: ColorScience.linearToSrgb(c.g),
  blue: ColorScience.linearToSrgb(c.b),
);

/// A screen colour in linear light (unrounded).
LinearRgb linearOf(Color c) => LinearRgb(
  ColorScience.srgbToLinear(c.r),
  ColorScience.srgbToLinear(c.g),
  ColorScience.srgbToLinear(c.b),
);
