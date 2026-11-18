// Phase 9 §5 para 3 (user decision 2026-10-31) / plan D9, O8: a rail opts in
// to telling its surface whether the user is looking into it — at its start
// offset or scrolled in, and whether a pointer (finger, mouse button,
// trackpad pan) is down on it. A surface-supplied notice floats over the rail
// without moving anything, and a caption sits under the title. The recents
// rail passes none of these and is unchanged (its own tests).
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';

import '../browse_harness.dart';

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'Seven',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

List<FeedEntity> _rail(int n) => [
  for (var i = 0; i < n; i++) TrackEntity(_track('t$i')),
];

const _viewport = 400.0;

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late List<RailEngagement> reports;
  late int noticeTaps;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    reports = [];
    noticeTaps = 0;
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpRail(
    WidgetTester tester, {
    int count = 10,
    bool engagement = true,
    bool notice = false,
    String? subtitle,
    Object? resetToken,
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
                id: 'rediscover',
                title: 'Rediscover',
                subtitle: subtitle,
                entities: _rail(count),
                resetToken: resetToken,
                onEngagementChanged: engagement ? reports.add : null,
                notice: notice
                    ? RailNotice(
                        message: 'New listening activity',
                        actionLabel: 'Refresh',
                        onTap: () => noticeTaps++,
                      )
                    : null,
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
          of: find.byKey(const ValueKey('feed.rail.rediscover.body')),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  Offset cardCenter(WidgetTester tester, String id) =>
      tester.getCenter(find.byKey(ValueKey('track:$id')));

  const atRest = RailEngagement(atStart: true, pointerDown: false);
  const touchedAtStart = RailEngagement(atStart: true, pointerDown: true);

  test('at rest means at the start with no pointer down', () {
    expect(atRest.atRest, isTrue);
    expect(touchedAtStart.atRest, isFalse);
    expect(
      const RailEngagement(atStart: false, pointerDown: false).atRest,
      isFalse,
    );
    expect(atRest, const RailEngagement(atStart: true, pointerDown: false));
  });

  group('engagement', () {
    testWidgets('a pointer down at the start is reported, and its release',
        (tester) async {
      await pumpRail(tester);
      final gesture = await tester.startGesture(cardCenter(tester, 't0'));
      await tester.pump();
      expect(reports.last, touchedAtStart);
      await gesture.up();
      await tester.pump();
      expect(reports.last, atRest);
      await teardownTree(tester);
    });

    testWidgets('a cancelled pointer is no longer down', (tester) async {
      await pumpRail(tester);
      final gesture = await tester.startGesture(cardCenter(tester, 't0'));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      expect(reports.last, atRest);
      await teardownTree(tester);
    });

    testWidgets('two pointers: still down until the last one lifts', (
      tester,
    ) async {
      await pumpRail(tester);
      final a = await tester.startGesture(cardCenter(tester, 't0'), pointer: 1);
      final b = await tester.startGesture(cardCenter(tester, 't1'), pointer: 2);
      await tester.pump();
      await a.up();
      await tester.pump();
      expect(reports.last.pointerDown, isTrue);
      await b.up();
      await tester.pump();
      expect(reports.last, atRest);
      await teardownTree(tester);
    });

    testWidgets('a trackpad pan counts as a pointer down', (tester) async {
      await pumpRail(tester);
      final gesture = await tester.startGesture(
        cardCenter(tester, 't1'),
        kind: PointerDeviceKind.trackpad,
      );
      await tester.pump();
      expect(reports.last.pointerDown, isTrue);
      await gesture.up();
      await tester.pump();
      expect(reports.last.pointerDown, isFalse);
      await teardownTree(tester);
    });

    testWidgets('dragging into the rail: scrolled in; back to the start: at '
        'the start', (tester) async {
      await pumpRail(tester);
      final gesture = await tester.startGesture(cardCenter(tester, 't1'));
      // The first move past the touch slop scrolls nothing.
      await gesture.moveBy(const Offset(-100, 0));
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(rail(tester).pixels, greaterThan(0));
      expect(
        reports.last,
        const RailEngagement(atStart: false, pointerDown: true),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        reports.last,
        const RailEngagement(atStart: false, pointerDown: false),
      );

      rail(tester).jumpTo(0);
      await tester.pump();
      expect(reports.last, atRest);
      await teardownTree(tester);
    });

    testWidgets('only changes are reported', (tester) async {
      await pumpRail(tester);
      rail(tester).jumpTo(100);
      await tester.pump();
      rail(tester).jumpTo(200);
      await tester.pump();
      rail(tester).jumpTo(300);
      await tester.pump();
      expect(
        reports.where((r) => r == const RailEngagement(atStart: false, pointerDown: false)),
        hasLength(1),
      );
      await teardownTree(tester);
    });

    testWidgets('a new reset token puts a scrolled rail back at its start and '
        'says so', (tester) async {
      await pumpRail(tester, resetToken: 1);
      rail(tester).jumpTo(300);
      await tester.pump();
      expect(reports.last.atStart, isFalse);
      await pumpRail(tester, resetToken: 2);
      await tester.pump();
      expect(rail(tester).pixels, 0);
      expect(reports.last, atRest);
      await teardownTree(tester);
    });

    testWidgets('re-check N1: a scroll that starts and ends while scrolled in '
        'is reported, even though the value is the same', (tester) async {
      await pumpRail(tester);
      rail(tester).jumpTo(300);
      await tester.pump();
      final before = reports.length;
      expect(reports.last.atStart, isFalse);
      rail(tester).animateTo(
        500,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      expect(reports.length, greaterThan(before));
      expect(reports.last, const RailEngagement(atStart: false, pointerDown: false));
      await teardownTree(tester);
    });

    testWidgets('without the opt-in nothing is reported', (tester) async {
      await pumpRail(tester, engagement: false);
      final gesture = await tester.startGesture(cardCenter(tester, 't0'));
      await gesture.moveBy(const Offset(-200, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(reports, isEmpty);
      await teardownTree(tester);
    });
  });

  group('notice and caption', () {
    testWidgets('a supplied notice shows its copy, taps through, and moves '
        'nothing', (tester) async {
      await pumpRail(tester);
      rail(tester).jumpTo(300);
      await tester.pump();
      final cardBefore = tester.getTopLeft(find.byKey(const ValueKey('track:t2')));
      final bodyBefore = tester.getSize(
        find.byKey(const ValueKey('feed.rail.rediscover.body')),
      );
      expect(find.byType(NewActivityNotice), findsNothing);

      await pumpRail(tester, notice: true);
      expect(find.text('New listening activity'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(rail(tester).pixels, 300);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('track:t2'))),
        cardBefore,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('feed.rail.rediscover.body'))),
        bodyBefore,
      );

      await tester.tap(find.text('Refresh'));
      await tester.pump();
      expect(noticeTaps, 1);
      await teardownTree(tester);
    });

    testWidgets('the caption sits under the title, above the cards', (
      tester,
    ) async {
      await pumpRail(
        tester,
        subtitle: 'Tracks you enjoyed, but haven’t played in two weeks',
      );
      final caption = find.text(
        'Tracks you enjoyed, but haven’t played in two weeks',
      );
      expect(caption, findsOneWidget);
      final title = tester.getTopLeft(find.text('Rediscover')).dy;
      final captionY = tester.getTopLeft(caption).dy;
      final card = tester.getTopLeft(find.byKey(const ValueKey('track:t0'))).dy;
      expect(title < captionY && captionY < card, isTrue);
      await teardownTree(tester);
    });
  });
}
