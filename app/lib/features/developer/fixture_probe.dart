import '../../core/model/channel_layout.dart';

/// The five LED outputs every ElectroBright board has, in PROBE order (the
/// index is the PROBE output number): red GPIO 1, green 3, blue 4,
/// white/cool 5, warm 10.
enum ProbeOutput { red, green, blue, white, warm }

/// The fixture types in the order the firmware lists them (CAPS `TYPES=`).
const List<ChannelLayout> fixtureTypes = <ChannelLayout>[
  ChannelLayout.rgbw,
  ChannelLayout.rgb,
  ChannelLayout.rgbcct,
  ChannelLayout.cct,
  ChannelLayout.w,
];

/// The board outputs a fixture type drives.
Set<ProbeOutput> outputsOf(ChannelLayout layout) => <ProbeOutput>{
  for (final ChannelRole r in layout.roles)
    switch (r) {
      ChannelRole.r => ProbeOutput.red,
      ChannelRole.g => ProbeOutput.green,
      ChannelRole.b => ProbeOutput.blue,
      ChannelRole.w || ChannelRole.cw => ProbeOutput.white,
      ChannelRole.ww => ProbeOutput.warm,
    },
};

/// The fixture type that drives exactly the outputs that lit up in the probe
/// test, or null when no type matches (R+G+B is RGB, R+G+B+W RGBW,
/// R+G+B+W+warm RGB + CCT, W+warm tunable white, W alone white).
ChannelLayout? suggestType(Set<ProbeOutput> lit) {
  for (final ChannelLayout t in fixtureTypes) {
    final Set<ProbeOutput> o = outputsOf(t);
    if (o.length == lit.length && o.containsAll(lit)) return t;
  }
  return null;
}
