// Phase 6 §6 (6-R06): a live entity rail keeps the first visible entity
// and its intra-card pixel offset across inserts, reorders, removals and
// payload-only updates; at offset zero it shows the newest; a removed
// anchor clamps; when the kept anchor hides newer activity, a small
// "New activity" notice (O7: `NewActivityNotice` without an action label)
// returns to the start.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';

import '../browse_harness.dart';

TrackUI _track(String uuid, {String? title}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title ?? 'Song $uuid',
  artist: 'Seven',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

List<FeedEntity> _rail(List<String> ids, {String suffix = ''}) => [
  for (final id in ids) TrackEntity(_track(id, title: 'Song $id$suffix')),
];

const _w = FeedCardExtent.cardWidth; // 160
const _pad = 8.0; // the rail's horizontal padding
const _viewport = 400.0;

double _at(int index, double intra) => _pad + index * _w + intra;

List<String> _ids(int n, [String prefix = 't']) => [
  for (var i = 0; i < n; i++) '$prefix$i',
];

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  final taps = <String>[];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    taps.clear();
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpRail(
    WidgetTester tester,
    List<FeedEntity> entities, {
    String? newActivityLabel,
    RailState state = RailState.ready,
  }) async {
    tester.view.physicalSize = const Size(_viewport, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: SectionedFeedView(
            sections: [
              EntityRailSection(
                id: 'recents',
                title: 'Recently played',
                entities: entities,
                state: state,
                newActivityLabel: newActivityLabel,
                onTap: (e, _) => taps.add((e.key as ValueKey<String>).value),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ScrollPosition rail(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('feed.rail.recents.body')),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  double dx(WidgetTester tester, String id) =>
      tester.getTopLeft(find.byKey(ValueKey('track:$id'))).dx;

  group('anchor', () {
    testWidgets('a prepend while scrolled keeps the visible key at the same '
        'pixel', (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      final before = dx(tester, 't2');

      await pumpRail(tester, _rail(['n1', 'n0', ..._ids(10)]));
      expect(rail(tester).pixels, closeTo(_at(4, 30), 1e-6));
      expect(dx(tester, 't2'), closeTo(before, 1e-6));
      await teardownTree(tester);
    });

    testWidgets('a tap after a prepend reaches the card under the pointer',
        (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      final point = tester.getCenter(find.byKey(const ValueKey('track:t2')));

      await pumpRail(tester, _rail(['n1', 'n0', ..._ids(10)]));
      await tester.tapAt(point);
      await tester.pump();
      expect(taps, ['track:t2']);
      await teardownTree(tester);
    });

    testWidgets('at offset zero a prepend shows the newest', (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      expect(rail(tester).pixels, 0);

      await pumpRail(tester, _rail(['n0', ..._ids(10)]));
      expect(rail(tester).pixels, 0);
      expect(dx(tester, 'n0'), closeTo(_pad, 1e-6));
      await teardownTree(tester);
    });

    testWidgets('a payload-only update does not move the rail',
        (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      rail(tester).jumpTo(_at(3, 12));
      await tester.pump();

      await pumpRail(tester, _rail(_ids(10), suffix: ' (renamed)'));
      expect(rail(tester).pixels, closeTo(_at(3, 12), 1e-6));
      expect(find.text('Song t3 (renamed)'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a removed anchor is replaced by its successor at the same '
        'pixel', (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      final before = dx(tester, 't2');

      await pumpRail(
        tester,
        // A newer entity arrives at the front in the same update, so the
        // same numeric offset would show a different card.
        _rail(['n0', for (final id in _ids(10)) if (id != 't2') id]),
      );
      expect(find.byKey(const ValueKey('track:t2')), findsNothing);
      expect(dx(tester, 't3'), closeTo(before, 1e-6));
      await teardownTree(tester);
    });

    testWidgets('removing the anchor and everything after it clamps to the '
        'new end', (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      final p = rail(tester);
      p.jumpTo(p.maxScrollExtent);
      await tester.pump();

      await pumpRail(tester, _rail(_ids(4)));
      await tester.pumpAndSettle();
      final max = 2 * _pad + 4 * _w - _viewport;
      expect(rail(tester).pixels, closeTo(max, 1e-6));
      expect(rail(tester).maxScrollExtent, closeTo(max, 1e-6));
      expect(tester.takeException(), isNull);
      await teardownTree(tester);
    });
  });

  // Review r1 minor 1: during a fling the correction must survive the next
  // frame, even when the item count is unchanged (Home at its cap).
  testWidgets('a reorder during a fling keeps the anchor on the next frame',
      (tester) async {
    await pumpRail(tester, _rail(_ids(20)));
    rail(tester).jumpTo(1000);
    await tester.pump();
    await tester.fling(
      find.byKey(const ValueKey('track:t6')),
      const Offset(-300, 0),
      1000,
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 50));
    // The card in the middle of the viewport (fully visible).
    final key =
        't${((rail(tester).pixels - _pad + _viewport / 2) / _w).floor()}';
    final before = dx(tester, key);

    // t19 is clicked again: it moves to the front, the count stays 20.
    await pumpRail(tester, _rail(['t19', ..._ids(19)]));
    await tester.pump(const Duration(milliseconds: 16));
    // The fling keeps moving (a few pixels per frame), but the card under
    // the pointer doesn't jump by a card width.
    expect((dx(tester, key) - before).abs(), lessThan(_w / 4));
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  // Review r1 minor 2: a new result set after loading (a chip change or a
  // retry) starts at the beginning, not at the old numeric offset.
  testWidgets('ready again after loading starts at the start', (tester) async {
    await pumpRail(tester, _rail(_ids(12)));
    rail(tester).jumpTo(_at(5, 0));
    await tester.pump();
    await pumpRail(tester, const [], state: RailState.loading);
    await pumpRail(tester, _rail(_ids(12, 'd')));
    await tester.pump();
    expect(rail(tester).pixels, 0);
    expect(dx(tester, 'd0'), closeTo(_pad, 1e-6));
    await teardownTree(tester);
  });

  group('New activity', () {
    testWidgets('appears when the kept anchor hides newer activity; tapping '
        'it returns to the start and hides it', (tester) async {
      await pumpRail(tester, _rail(_ids(10)), newActivityLabel: 'New activity');
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      expect(find.byType(NewActivityNotice), findsNothing);

      await pumpRail(
        tester,
        _rail(['n0', ..._ids(10)]),
        newActivityLabel: 'New activity',
      );
      expect(find.text('New activity'), findsOneWidget);
      // The anchor is still kept: nothing moved under the pointer.
      expect(rail(tester).pixels, closeTo(_at(3, 30), 1e-6));

      await tester.tap(find.text('New activity'));
      await tester.pumpAndSettle();
      expect(rail(tester).pixels, 0);
      expect(dx(tester, 'n0'), closeTo(_pad, 1e-6));
      expect(find.byType(NewActivityNotice), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('showing it moves nothing vertically', (tester) async {
      await pumpRail(tester, _rail(_ids(10)), newActivityLabel: 'New activity');
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      final body = find.byKey(const ValueKey('feed.rail.recents.body'));
      final top = tester.getTopLeft(body).dy;
      final bottom = tester.getBottomLeft(body).dy;
      await pumpRail(
        tester,
        _rail(['n0', ..._ids(10)]),
        newActivityLabel: 'New activity',
      );
      expect(find.byType(NewActivityNotice), findsOneWidget);
      expect(tester.getTopLeft(body).dy, top);
      expect(tester.getBottomLeft(body).dy, bottom);
      await teardownTree(tester);
    });

    testWidgets('scrolling back to the start by hand hides it',
        (tester) async {
      await pumpRail(tester, _rail(_ids(10)), newActivityLabel: 'New activity');
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      await pumpRail(
        tester,
        _rail(['n0', ..._ids(10)]),
        newActivityLabel: 'New activity',
      );
      expect(find.byType(NewActivityNotice), findsOneWidget);

      rail(tester).jumpTo(0);
      await tester.pump();
      expect(find.byType(NewActivityNotice), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('not shown at offset zero, for a payload-only update, or '
        'for a removal', (tester) async {
      await pumpRail(tester, _rail(_ids(10)), newActivityLabel: 'New activity');
      await pumpRail(
        tester,
        _rail(['n0', ..._ids(10)]),
        newActivityLabel: 'New activity',
      );
      expect(find.byType(NewActivityNotice), findsNothing);

      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      await pumpRail(
        tester,
        _rail(['n0', ..._ids(10)], suffix: '!'),
        newActivityLabel: 'New activity',
      );
      expect(find.byType(NewActivityNotice), findsNothing);

      await pumpRail(
        tester,
        _rail(_ids(10).where((id) => id != 't0').toList()),
        newActivityLabel: 'New activity',
      );
      expect(find.byType(NewActivityNotice), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a rail without a label never shows it', (tester) async {
      await pumpRail(tester, _rail(_ids(10)));
      rail(tester).jumpTo(_at(2, 30));
      await tester.pump();
      await pumpRail(tester, _rail(['n0', ..._ids(10)]));
      expect(find.byType(NewActivityNotice), findsNothing);
      // The anchor is kept regardless.
      expect(rail(tester).pixels, closeTo(_at(3, 30), 1e-6));
      await teardownTree(tester);
    });
  });
}
