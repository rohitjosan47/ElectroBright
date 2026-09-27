import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The Groups card on Home: a half per group of 2+ lights, each opening its
/// group; it connects nothing.
void main() {
  final Finder card = find.byKey(const ValueKey<String>('groups-card'));
  Finder half(String kind) => find.byKey(ValueKey<String>('group-card-$kind'));

  Future<DemoApp> start(
    WidgetTester t,
    Map<String, (String, ChannelLayout)> lights,
  ) async {
    t.view.physicalSize = const Size(393, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t, lights: lights);
    await DemoApp.settle(t, 3);
    return d;
  }

  testWidgets('both groups: two halves, each opening its group; leaving it '
      'releases its connections after the idle grace', (WidgetTester t) async {
    final DemoApp d = await start(t, DemoApp.groupLights);
    expect(card, findsOneWidget);
    expect(half('colour'), findsOneWidget);
    expect(half('white'), findsOneWidget);
    expect(find.bySemanticsLabel('Colour lights'), findsOneWidget);
    expect(find.bySemanticsLabel('White lights'), findsOneWidget);
    // Home keeps three lights connected (the colour ones); the card
    // connects nothing.
    expect(find.text('3 of 3 connected'), findsOneWidget);
    expect(find.text('0 of 2 connected'), findsOneWidget);
    // Side by side.
    expect(
      t.getTopLeft(half('white')).dx,
      greaterThan(t.getTopLeft(half('colour')).dx),
    );
    const List<String> all = <String>[
      'Desk strip',
      'Living room',
      'Reading lamp',
      'Kitchen',
      'Hallway',
    ];
    int ready() => all.where((String n) => d.session(n).status.isReady).length;
    expect(ready(), 3);

    await t.tap(half('white'));
    await DemoApp.settle(t, 5);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.text('White lights'), findsOneWidget);
    expect(ready(), 5);
    await t.tap(find.byIcon(Icons.chevron_left_rounded).first);
    await DemoApp.settle(t, 65);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await DemoApp.settle(t, 1);
    expect(find.byType(GroupScreen), findsNothing);
    expect(ready(), 3);
    await t.tap(half('colour'));
    await DemoApp.settle(t, 3);
    expect(find.text('Colour lights'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('one group: its half at full width', (WidgetTester t) async {
    await start(t, <String, (String, ChannelLayout)>{
      'Desk strip': ('demo-rgb', ChannelLayout.rgb),
      'Living room': ('demo-rgbw', ChannelLayout.rgbw),
      'Kitchen': ('demo-cct', ChannelLayout.cct),
    });
    expect(card, findsOneWidget);
    expect(half('colour'), findsOneWidget);
    expect(half('white'), findsNothing);
    expect(t.getSize(half('colour')).width, greaterThan(300));
    await DemoApp.shutDown(t);
  });

  testWidgets('no group of two: no card', (WidgetTester t) async {
    await start(t, <String, (String, ChannelLayout)>{
      'Desk strip': ('demo-rgb', ChannelLayout.rgb),
      'Kitchen': ('demo-cct', ChannelLayout.cct),
    });
    expect(card, findsNothing);
    await DemoApp.shutDown(t);
  });
}
