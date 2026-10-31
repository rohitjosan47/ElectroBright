import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('kelvin sweep is stable through echoes', () {
    final ColourEngine e = ColourEngine(const LedWhitePoints());
    final r = e.whiteRange(ChannelLayout.rgbcct);
    int jumps = 0, rgbLeaks = 0;
    for (final double level in <double>[0.05, 0.2, 0.5, 1]) {
      for (double k = r.min; k <= r.max; k += 25) {
        final WhiteIntent w = WhiteIntent(k, level);
        final ChannelColor c = e.encode(w, ChannelLayout.rgbcct);
        if (c[0] + c[1] + c[2] != 0) rgbLeaks++;
        for (final int d in <int>[0, 1, -1]) {
          final ChannelColor echo = ChannelColor(ChannelLayout.rgbcct, <int>[
            0,
            0,
            0,
            (c[3] + d).clamp(0, 255),
            c[4],
          ]);
          if (e.decode(echo, hint: w) != w) jumps++;
        }
      }
    }
    expect(rgbLeaks, 0);
    expect(jumps, 0);
  });

  test('the mired midpoint (slider centre) is both whites at full', () {
    const LedWhitePoints wp = LedWhitePoints();
    final double mid = 1e6 / ((1e6 / wp.wwK + 1e6 / wp.cwK) / 2);
    final ChannelColor c = ColourEngine(wp)
        .encode(WhiteIntent(mid, 1), ChannelLayout.rgbcct);
    expect(c.values, <int>[0, 0, 0, 255, 255]);
  });
}
