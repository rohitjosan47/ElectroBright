import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/features/developer/fixture_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Find the right type": every combination of lit outputs gives the type
/// that drives exactly those outputs, or no suggestion.
void main() {
  const ProbeOutput r = ProbeOutput.red;
  const ProbeOutput g = ProbeOutput.green;
  const ProbeOutput b = ProbeOutput.blue;
  const ProbeOutput w = ProbeOutput.white;
  const ProbeOutput ww = ProbeOutput.warm;

  test('the five matching combinations', () {
    expect(suggestType(<ProbeOutput>{r, g, b}), ChannelLayout.rgb);
    expect(suggestType(<ProbeOutput>{r, g, b, w}), ChannelLayout.rgbw);
    expect(suggestType(<ProbeOutput>{r, g, b, w, ww}), ChannelLayout.rgbcct);
    expect(suggestType(<ProbeOutput>{w, ww}), ChannelLayout.cct);
    expect(suggestType(<ProbeOutput>{w}), ChannelLayout.w);
  });

  test('every other combination matches no type', () {
    const Map<int, ChannelLayout> matches = <int, ChannelLayout>{
      0x07: ChannelLayout.rgb, // r g b
      0x0F: ChannelLayout.rgbw, // r g b w
      0x1F: ChannelLayout.rgbcct, // r g b w ww
      0x18: ChannelLayout.cct, // w ww
      0x08: ChannelLayout.w, // w
    };
    for (int mask = 0; mask < 32; mask++) {
      final Set<ProbeOutput> lit = <ProbeOutput>{
        for (final ProbeOutput o in ProbeOutput.values)
          if (mask & (1 << o.index) != 0) o,
      };
      expect(suggestType(lit), matches[mask], reason: '$lit');
    }
  });

  test('the outputs of each type are its LEDs (PROBE order)', () {
    expect(ProbeOutput.values.map((ProbeOutput o) => o.index), <int>[
      0,
      1,
      2,
      3,
      4,
    ]);
    for (final ChannelLayout t in fixtureTypes) {
      expect(outputsOf(t), hasLength(t.n), reason: t.wire);
      expect(suggestType(outputsOf(t)), t);
    }
    // The firmware's TYPES= order.
    expect(
      fixtureTypes.map((ChannelLayout t) => t.wire).join(','),
      'RGBW,RGB,RGBCCT,CCT,W',
    );
  });
}
