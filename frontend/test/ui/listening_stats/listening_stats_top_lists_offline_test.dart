// Phase 9A.2b exit proof "offline, a remote-only card is dimmed" (spec §4
// para 2 "Offline play gating/download menu behavior remains shared";
// SC-06; review 9-S07 unit half): offline, the statistics page's top cards
// use the shared availability rule and the shared menu. A remote-only track
// dims and does not play but keeps Get info; a downloaded one plays; a
// collection card still opens its detail page. Real Drift download state,
// fake statistics controller.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse_harness.dart' show teardownTree;
import 'top_lists_fixtures.dart';

void main() {
  late TopListsHarness h;
  setUp(() async {
    h = TopListsHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  ListTile menuTile(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
  );

  testWidgets('offline: a remote-only top track is dimmed and does not play; '
      'a downloaded one plays', (tester) async {
    await h.open(tester, lists(), offline: true);
    expect(opacityOf(tester, 'track:t-a'), lessThan(1));
    expect(opacityOf(tester, 'track:t-b'), 1);
    await tester.tap(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(h.fake.played, isEmpty);
    await tester.tap(inCard('track:t-b', 'Same'));
    await tester.pumpAndSettle();
    expect(h.fake.played, ['t-b']);
    await teardownTree(tester);
  });

  testWidgets('online: the remote-only track is not dimmed', (tester) async {
    await h.open(tester, lists());
    expect(opacityOf(tester, 'track:t-a'), 1);
    await teardownTree(tester);
  });

  testWidgets('offline: the remote-only track\'s shared menu blocks queueing '
      'but keeps Get info', (tester) async {
    await h.open(tester, lists(), offline: true);
    await tester.longPress(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(menuTile(tester, 'Get Info').enabled, isTrue);
    expect(menuTile(tester, 'Play Next').enabled, isFalse);
    expect(menuTile(tester, 'Add to Queue').enabled, isFalse);
    await teardownTree(tester);
  });

  testWidgets('offline: a remote-only album still opens its detail page',
      (tester) async {
    await h.open(tester, lists(), offline: true);
    await tester.tap(inCard('album:10', 'One'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'One'), findsOneWidget);
    expect(h.browse.audio.calls, isEmpty);
    await teardownTree(tester);
  });
}
