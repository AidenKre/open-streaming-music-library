import 'dart:async';

import 'package:drift/drift.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/widgets/full_player.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import 'fake_player_controls.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_offline.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    repo = QueueRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('a failed queue read settles and Retry loads the rows',
      (tester) async {
    await _seedQueueTracks(db, ['a']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'test', trackUuids: const ['a'],
    );
    final snapshot = (await repo.getSessionSnapshot(sessionId))!;
    final failingRepo = _FailOnceQueueRepository(db);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
      queueRepositoryProvider.overrideWithValue(failingRepo),
      playerControlsProvider.overrideWithValue(FakePlayerControls()),
      queuePlayerProvider.overrideWith(() => _TestQueuePlayer(_audioStateFor(
        sessionId: sessionId,
        currentItemId: snapshot.currentItem!.itemId,
        currentPlayPosition: 0,
        totalCount: 1,
        currentTrack: _track('a'),
      ))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: FullPlayer())),
    ));
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('Error loading queue'), findsOneWidget);
    expect(failingRepo.pageReads, 1, reason: 'failure does not poll');
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Error loading queue'), findsNothing);
    expect(find.text('Track A'), findsOneWidget);
    expect(failingRepo.pageReads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Other-issues row 69: a failed read with rows on screen said nothing.
  testWidgets('a failed queue read with rows on screen shows the error and '
      'Retry above the rows', (tester) async {
    await _seedQueueTracks(db, ['a', 'b', 'c']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'test', trackUuids: const ['a', 'b', 'c'],
    );
    final snapshot = (await repo.getSessionSnapshot(sessionId))!;
    final failingRepo = _FailNextPageQueueRepository(db);
    final notifier = _MutableTestQueuePlayer(_audioStateFor(
      sessionId: sessionId,
      currentItemId: snapshot.currentItem!.itemId,
      currentPlayPosition: 0,
      totalCount: 3,
      currentTrack: _track('a'),
    ));
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
      queueRepositoryProvider.overrideWithValue(failingRepo),
      playerControlsProvider.overrideWithValue(FakePlayerControls()),
      queuePlayerProvider.overrideWith(() => notifier),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: FullPlayer())),
    ));
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('Track B'), findsOneWidget);
    expect(find.text('Error loading queue'), findsNothing);

    // A queue edit re-reads the visible rows; that read fails.
    failingRepo.failNextPage = true;
    notifier.setQueueState(notifier.state.queue
        .copyWith(queueVersion: notifier.state.queue.queueVersion + 1));
    await tester.pumpAndSettle();
    expect(find.text('Error loading queue'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Track B'), findsOneWidget, reason: 'the rows stay');
    expect(
        tester.getTopLeft(find.text('Error loading queue')).dy,
        lessThan(tester.getTopLeft(find.text('Track A')).dy),
        reason: 'above the rows');

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Error loading queue'), findsNothing);
    expect(find.text('Track C'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Pre-merge R2-L-01 (second live run): the open Queue tab lost the playing
  // track in a burst of skips. It scrolled to the playing track only when a
  // load of new rows completed, and such a load starts when the playing track
  // first leaves the loaded rows: in the middle of a burst, or never.
  group('the open Queue tab keeps the playing row in view through a burst of '
      'skips', () {
    late _HeldPageQueueRepository pages;
    late _MutableTestQueuePlayer notifier;
    late List<QueuePlaybackEntry> entries;

    /// Opens the Queue tab on 160 tracks, the first one playing: rows 1 to
    /// 101 are loaded (the playing one and 60 after it; none before).
    Future<ScrollPosition> openLongQueue(WidgetTester tester) async {
      final uuids = [
        for (var i = 0; i < 160; i++) 't${i.toString().padLeft(3, '0')}',
      ];
      await _seedQueueTracks(db, uuids);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'test', trackUuids: uuids,
      );
      entries = await repo.getPlaybackEntries(sessionId);
      pages = _HeldPageQueueRepository(db);
      notifier = _MutableTestQueuePlayer(_audioStateFor(
        sessionId: sessionId,
        currentItemId: entries[0].itemId,
        currentPlayPosition: 0,
        totalCount: 160,
        currentTrack: _track('t000'),
      ));
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        queueRepositoryProvider.overrideWithValue(pages),
        playerControlsProvider.overrideWithValue(FakePlayerControls()),
        queuePlayerProvider.overrideWith(() => notifier),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FullPlayer())),
      ));
      await tester.tap(find.text('Queue'));
      await tester.pumpAndSettle();
      expect(playingRowShown(), isTrue, reason: 'precondition: at open');
      return tester
          .state<ScrollableState>(find.descendant(
              of: find.byKey(const ValueKey('queue rows')),
              matching: find.byType(Scrollable)))
          .position;
    }

    /// One skip: the playing track becomes the one at [playPosition]; a frame
    /// 40 ms later (the live driver's pace).
    Future<void> skipTo(WidgetTester tester, int playPosition) async {
      notifier.setQueueState(notifier.state.queue.copyWith(
          currentItemId: entries[playPosition].itemId,
          currentPlayPosition: playPosition));
      await tester.pump(const Duration(milliseconds: 40));
    }

    testWidgets('70 skips inside the loaded rows: the playing row stays in '
        'view, with no read at all', (tester) async {
      await openLongQueue(tester);
      final readsAtOpen = pages.pageReads;
      for (var p = 1; p <= 70; p++) {
        await skipTo(tester, p);
      }
      await tester.pumpAndSettle();
      expect(playingRowShown(), isTrue,
          reason: 'track 71 plays: its row is on screen');
      expect(find.text('Track T070'), findsOneWidget);
      expect(pages.pageReads - readsAtOpen, 0, reason: 'no read per skip');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a burst of 65 skips past the rows loaded at open: the '
        'playing row is in view when it settles, and the burst costs one '
        'read, not one per skip', (tester) async {
      await openLongQueue(tester);
      for (var p = 1; p <= 70; p++) {
        await skipTo(tester, p);
      }
      final readsBefore = pages.pageReads;
      for (var p = 71; p <= 135; p++) {
        await skipTo(tester, p);
      }
      await tester.pumpAndSettle();
      expect(find.text('Track T135'), findsOneWidget,
          reason: 'the rows around the playing track are loaded and built');
      expect(playingRowShown(), isTrue,
          reason: 'track 136 plays: its row is on screen');
      expect(pages.pageReads - readsBefore, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the same burst with a slow read: skips keep arriving while '
        'it is in flight and after it completes; the playing row is in view '
        'when the burst settles', (tester) async {
      await openLongQueue(tester);
      for (var p = 1; p <= 70; p++) {
        await skipTo(tester, p);
      }
      final readsBefore = pages.pageReads;
      // The next read is held while the playing track passes the last
      // loaded row (the 101st) and nine more skips arrive; it completes in
      // the middle of the burst.
      final held = pages.hold = Completer<void>();
      for (var p = 71; p <= 110; p++) {
        await skipTo(tester, p);
      }
      expect(held.isCompleted, isFalse);
      expect(pages.hold == null, isTrue,
          reason: 'precondition: a read is in flight');
      held.complete();
      for (var p = 111; p <= 135; p++) {
        await skipTo(tester, p);
      }
      await tester.pumpAndSettle();
      expect(find.text('Track T135'), findsOneWidget,
          reason: 'the rows around the playing track are loaded and built');
      expect(playingRowShown(), isTrue,
          reason: 'track 136 plays: its row is on screen');
      expect(pages.pageReads - readsBefore, lessThanOrEqualTo(2),
          reason: 'the held read and at most one load around the playing '
              'track; never one per skip');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // Review finding 2: the jump after rows were added above the list used
    // the scroll offset from before the read, undoing a follow made since.
    testWidgets('a burst of Previous towards the first loaded rows with a '
        'slow read of the rows above: the playing row is in view when the '
        'burst settles', (tester) async {
      final position = await openLongQueue(tester);
      // Far down first: rows 91 to 160 are loaded around track 131.
      await skipTo(tester, 130);
      await tester.pumpAndSettle();
      expect(playingRowShown(), isTrue, reason: 'precondition');
      final readsBefore = pages.pageReads;
      final extentBefore = position.maxScrollExtent;
      // The read of the rows above (started when the list nears its top) is
      // held while more skips arrive, down to the first loaded row.
      final held = pages.hold = Completer<void>();
      for (var p = 129; p >= 90; p--) {
        await skipTo(tester, p);
      }
      expect(pages.pageReads - readsBefore, 1,
          reason: 'precondition: only the read of the rows above, in flight');
      expect(playingRowShown(), isTrue, reason: 'followed up to here');
      held.complete();
      await tester.pumpAndSettle();
      expect(playingRowShown(), isTrue,
          reason: 'track 91 plays: its row is on screen');
      expect(position.maxScrollExtent, greaterThan(extentBefore + 1000),
          reason: 'with the rows read meanwhile above it');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a person who scrolled the playing row out of view is left '
        'where they are: skips inside the loaded rows move nothing',
        (tester) async {
      final position = await openLongQueue(tester);
      position.jumpTo(2600); // reading rows around the 40th
      await tester.pumpAndSettle();
      expect(playingRowShown(), isFalse, reason: 'precondition');
      final readsBefore = pages.pageReads;
      for (var p = 1; p <= 20; p++) {
        await skipTo(tester, p);
      }
      await tester.pumpAndSettle();
      expect(position.pixels, 2600, reason: 'no jump while reading the list');
      expect(pages.pageReads - readsBefore, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // Pre-merge D4-01: one failed page read far down a long queue.
  group('a failed read of later rows in a long queue', () {
    /// How far the list scrolls with only the first window loaded.
    late double firstWindowExtent;

    /// Opens the Queue tab on 200 tracks (the first window is rows 0 to 60),
    /// scrolls to its end with the next page read failing, and returns the
    /// list's scroll position with the notice on screen.
    Future<ScrollPosition> scrolledToFailedPage(WidgetTester tester) async {
      final uuids = [
        for (var i = 0; i < 200; i++) 't${i.toString().padLeft(3, '0')}',
      ];
      await _seedQueueTracks(db, uuids);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'test', trackUuids: uuids,
      );
      final snapshot = (await repo.getSessionSnapshot(sessionId))!;
      final failingRepo = _FailNextPageQueueRepository(db);
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        queueRepositoryProvider.overrideWithValue(failingRepo),
        playerControlsProvider.overrideWithValue(FakePlayerControls()),
        queuePlayerProvider.overrideWith(() => _TestQueuePlayer(_audioStateFor(
          sessionId: sessionId,
          currentItemId: snapshot.currentItem!.itemId,
          currentPlayPosition: 0,
          totalCount: 200,
          currentTrack: _track('t000'),
        ))),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FullPlayer())),
      ));
      await tester.tap(find.text('Queue'));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.descendant(
              of: find.byKey(const ValueKey('queue rows')),
              matching: find.byType(Scrollable)))
          .position;
      firstWindowExtent = position.maxScrollExtent;
      failingRepo.failNextPage = true;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Error loading queue'), findsOneWidget);
      return position;
    }

    testWidgets('scrolling on, the read succeeds: the rows load and the '
        'error goes away', (tester) async {
      final position = await scrolledToFailedPage(tester);
      position.jumpTo(position.maxScrollExtent - 5);
      await tester.pumpAndSettle();
      expect(position.maxScrollExtent, greaterThan(firstWindowExtent + 1000),
          reason: 'the next rows loaded');
      expect(find.text('Error loading queue'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Retry reads the rows that failed and keeps the place in the '
        'list', (tester) async {
      final position = await scrolledToFailedPage(tester);
      final place = position.pixels;
      expect(place, greaterThan(1000), reason: 'precondition: far down');
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Error loading queue'), findsNothing);
      expect(position.maxScrollExtent, greaterThan(firstWindowExtent + 1000),
          reason: 'the rows that failed are loaded');
      expect(position.pixels, closeTo(place, 1),
          reason: 'no jump back to the current track');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets(
    'queue shows separators only for current or future manual/main boundaries',
    (tester) async {
      await _seedQueueTracks(db, ['a', 'x', 'y', 'b']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b'],
        currentIndex: 0,
      );
      final currentItem = (await repo.getSessionSnapshot(
        sessionId,
      ))!.currentItem!;

      await repo.prependManualItems(sessionId, const ['x', 'y']);
      await repo.rebuildFutureSuffix(
        sessionId,
        currentItemId: currentItem.itemId,
        mainFutureItemIds: await repo.getFutureMainItemIds(
          sessionId,
          currentItemId: currentItem.itemId,
          usePlayOrder: false,
        ),
      );

      final atStartContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          queuePlayerProvider.overrideWith(
            () => _TestQueuePlayer(
              _audioStateFor(
                sessionId: sessionId,
                currentItemId: currentItem.itemId,
                currentPlayPosition: 0,
                totalCount: 4,
                currentTrack: _track('a'),
              ),
            ),
          ),
        ],
      );
      addTearDown(atStartContainer.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: atStartContainer,
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
          ),
        ),
      );
      await tester.tap(find.text('Queue'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('queue_type_separator')),
        findsNWidgets(2),
      );

      final afterManualContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          queuePlayerProvider.overrideWith(
            () => _TestQueuePlayer(
              _audioStateFor(
                sessionId: sessionId,
                currentItemId: currentItem.itemId,
                currentPlayPosition: 3,
                totalCount: 4,
                currentTrack: _track('b'),
              ),
            ),
          ),
        ],
      );
      addTearDown(afterManualContainer.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: afterManualContainer,
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
          ),
        ),
      );
      await tester.tap(find.text('Queue'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('queue_type_separator')), findsNothing);
    },
  );

  testWidgets(
    'removing a queue item while scrolled down preserves queue viewport',
    (tester) async {
      final uuids = List.generate(
        140,
        (index) => 't${index.toString().padLeft(3, '0')}',
      );
      await _seedQueueTracks(db, uuids);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: uuids,
        currentIndex: 0,
      );
      final snapshot = (await repo.getSessionSnapshot(sessionId))!;
      final notifier = _MutableTestQueuePlayer(
        _audioStateFor(
          sessionId: sessionId,
          currentItemId: snapshot.currentItem!.itemId,
          currentPlayPosition: 0,
          totalCount: uuids.length,
          currentTrack: _track(uuids.first),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          queuePlayerProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
          ),
        ),
      );
      await tester.tap(find.text('Queue'));
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Track T100'),
        400,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      expect(find.text('Track T100'), findsOneWidget);

      final removedEntry = (await repo.getPlaybackEntries(
        sessionId,
        startPlayPosition: 105,
        limit: 1,
      )).single;
      await repo.removeItem(sessionId, removedEntry.itemId);
      notifier.setQueueState(
        notifier.state.queue.copyWith(
          totalCount: uuids.length - 1,
          queueVersion: notifier.state.queue.queueVersion + 1,
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Track T100'), findsOneWidget);
      expect(find.text('Track T000'), findsNothing);
    },
  );

  group('offline dimming', () {
    Future<void> pumpQueue(WidgetTester tester, {required bool offline}) async {
      await _seedQueueTracks(db, ['a', 'b'], downloadedUuids: const {'a'});
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b'],
        currentIndex: 0,
      );
      final snapshot = (await repo.getSessionSnapshot(sessionId))!;

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          offlineModeProvider.overrideWith(() => TestOffline(offline)),
          queuePlayerProvider.overrideWith(
            () => _TestQueuePlayer(
              _audioStateFor(
                sessionId: sessionId,
                currentItemId: snapshot.currentItem!.itemId,
                currentPlayPosition: 0,
                totalCount: 2,
                currentTrack: _track('a'),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
          ),
        ),
      );
      await tester.tap(find.text('Queue'));
      await tester.pump();
      await tester.pumpAndSettle();
    }

    TrackTile tileFor(WidgetTester tester, String title) {
      return tester.widget<TrackTile>(find.ancestor(
        of: find.text(title),
        matching: find.byType(TrackTile),
      ));
    }

    testWidgets('offline: streaming-only row dimmed, downloaded row normal',
        (tester) async {
      await pumpQueue(tester, offline: true);

      expect(tileFor(tester, 'Track A').isDimmed, isFalse);
      expect(tileFor(tester, 'Track B').isDimmed, isTrue);
    });

    testWidgets('online: no row is dimmed for download state', (tester) async {
      await pumpQueue(tester, offline: false);

      expect(tileFor(tester, 'Track A').isDimmed, isFalse);
      expect(tileFor(tester, 'Track B').isDimmed, isFalse);
    });
  });

  group('cover art', () {
    setUpAll(() {
    });

    Future<void> pumpFullPlayer(
      WidgetTester tester,
      TrackUI track,
    ) async {
      await _seedQueueTracks(db, ['test-track']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'test',
        trackUuids: const ['test-track'],
        currentIndex: 0,
      );
      final snapshot = (await repo.getSessionSnapshot(sessionId))!;

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          queuePlayerProvider.overrideWith(
            () => _TestQueuePlayer(
              _audioStateFor(
                sessionId: sessionId,
                currentItemId: snapshot.currentItem!.itemId,
                currentPlayPosition: 0,
                totalCount: 1,
                currentTrack: track,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'track without art shows music note placeholder',
      (tester) async {
        await pumpFullPlayer(tester, _track('no-art'));

        expect(find.byIcon(Icons.music_note), findsWidgets);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'track with art shows CoverArtImage',
      (tester) async {
        final trackWithArt = TrackUI(
          uuidId: 'with-art',
          createdAt: 1,
          lastUpdated: 1,
          title: 'Art Track',
          artist: 'Artist',
          album: 'Album',
          duration: 180,
          bitrateKbps: 320,
          sampleRateHz: 44100,
          channels: 2,
          hasAlbumArt: true,
          coverArtId: 99,
        );
        await pumpFullPlayer(tester, trackWithArt);

        expect(find.byType(CoverArtImage), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
      },
    );
  });

  testWidgets('queue row tap and remove go to PlayerControls (SC-27)',
      (tester) async {
    await _seedQueueTracks(db, ['a', 'b', 'c']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 0,
    );
    final snapshot = (await repo.getSessionSnapshot(sessionId))!;
    final entries = await repo.getPlaybackEntries(sessionId);
    final controls = FakePlayerControls();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        playerControlsProvider.overrideWithValue(controls),
        queuePlayerProvider.overrideWith(
          () => _TestQueuePlayer(
            _audioStateFor(
              sessionId: sessionId,
              currentItemId: snapshot.currentItem!.itemId,
              currentPlayPosition: 0,
              totalCount: 3,
              currentTrack: _track('a'),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
        ),
      ),
    );
    await tester.tap(find.text('Queue'));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track C'));
    final rowB = find.ancestor(of: find.text('Track B'), matching: find.byType(TrackTile));
    await tester.tap(find.descendant(of: rowB, matching: find.byIcon(Icons.close)));
    expect(controls.calls, [
      'skipTo ${entries[2].itemId}',
      'remove ${entries[1].itemId}',
    ]);
  });

  testWidgets('an empty-queue Queue tab can be left without errors',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        queuePlayerProvider.overrideWith(
          () => _TestQueuePlayer(
            _audioStateFor(
              sessionId: 1,
              currentItemId: 1,
              currentPlayPosition: 0,
              totalCount: 0,
              currentTrack: _track('a'),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
        ),
      ),
    );
    await tester.tap(find.text('Queue'));
    await tester.pump();
    expect(find.text('Queue is empty'), findsOneWidget);
    // Leaving the tab disposes the queue view, which must not reach for a
    // controller it never created.
    await tester.tap(find.text('Now Playing'));
    await tester.pump();
    expect(tester.takeException(), equals(null));
  });
}

Future<void> _seedQueueTracks(
  AppDatabase db,
  List<String> uuids, {
  Set<String> downloadedUuids = const {},
}) async {
  await db.batch((batch) {
    batch.insert(
      db.artists,
      const ArtistsCompanion(id: Value(1), name: Value('Artist')),
    );
    batch.insert(
      db.albums,
      const AlbumsCompanion(
        id: Value(1),
        name: Value('Album'),
        artistId: Value(1),
        year: Value(2024),
        isSingleGrouping: Value(false),
      ),
    );

    for (var i = 0; i < uuids.length; i++) {
      final uuid = uuids[i];
      batch.insert(
        db.tracks,
        TracksCompanion(
          uuidId: Value(uuid),
          createdAt: Value(i + 1),
          lastUpdated: Value(i + 1),
          filePath: downloadedUuids.contains(uuid)
              ? Value('/downloads/$uuid.mp3')
              : const Value.absent(),
        ),
      );
      batch.insert(
        db.trackmetadata,
        TrackmetadataCompanion(
          uuidId: Value(uuid),
          title: Value('Track ${uuid.toUpperCase()}'),
          artist: const Value('Artist'),
          album: const Value('Album'),
          albumArtist: const Value('Artist'),
          artistId: const Value(1),
          albumId: const Value(1),
          year: const Value(2024),
          date: const Value('2024-01-01'),
          genre: const Value('Rock'),
          trackNumber: Value(i + 1),
          discNumber: const Value(1),
          codec: const Value('flac'),
          duration: const Value(180.0),
          bitrateKbps: const Value(320.0),
          sampleRateHz: const Value(44100),
          channels: const Value(2),
          hasAlbumArt: const Value(false),
        ),
      );
    }
  });
}

AudioState _audioStateFor({
  required int sessionId,
  required int currentItemId,
  required int currentPlayPosition,
  required int totalCount,
  required TrackUI currentTrack,
}) {
  return AudioState(
    playback: PlaybackSlice(
      currentTrack: currentTrack,
      status: PlayerStatus.playing,
      catalogDuration: const Duration(minutes: 3),
    ),
    queue: QueueSlice(
      sessionId: sessionId,
      currentItemId: currentItemId,
      currentPlayPosition: currentPlayPosition,
      totalCount: totalCount,
      queueVersion: 1,
    ),
  );
}

TrackUI _track(String uuidId) {
  return TrackUI(
    uuidId: uuidId,
    createdAt: 1,
    lastUpdated: 1,
    title: 'Track ${uuidId.toUpperCase()}',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}

class _FailOnceQueueRepository extends QueueRepository {
  _FailOnceQueueRepository(super.db);
  int pageReads = 0;

  @override
  Future<List<QueueTrackEntry>> getSessionTracksPage(int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) {
    if (++pageReads == 1) return Future.error(StateError('temporary read failure'));
    return super.getSessionTracksPage(sessionId,
        startPlayPosition: startPlayPosition, limit: limit);
  }
}

class _FailNextPageQueueRepository extends QueueRepository {
  _FailNextPageQueueRepository(super.db);
  bool failNextPage = false;

  @override
  Future<List<QueueTrackEntry>> getSessionTracksPage(int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) {
    if (failNextPage) {
      failNextPage = false;
      return Future.error(StateError('temporary read failure'));
    }
    return super.getSessionTracksPage(sessionId,
        startPlayPosition: startPlayPosition, limit: limit);
  }
}

/// Whether the playing track's row (the highlighted one) is on screen.
bool playingRowShown() => find
    .byWidgetPredicate((w) => w is TrackTile && w.isHighlighted)
    .hitTestable()
    .evaluate()
    .isNotEmpty;

/// Counts the page reads; with [hold] set, the next one waits for it.
class _HeldPageQueueRepository extends QueueRepository {
  _HeldPageQueueRepository(super.db);
  int pageReads = 0;
  Completer<void>? hold;

  @override
  Future<List<QueueTrackEntry>> getSessionTracksPage(int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) async {
    pageReads++;
    final held = hold;
    if (held != null) {
      hold = null;
      await held.future;
    }
    return super.getSessionTracksPage(sessionId,
        startPlayPosition: startPlayPosition, limit: limit);
  }
}

class _TestQueuePlayer extends QueuePlayer {
  final AudioState _initialState;

  _TestQueuePlayer(this._initialState);

  @override
  AudioState build() => _initialState;
}

class _MutableTestQueuePlayer extends QueuePlayer {
  final AudioState _initialState;

  _MutableTestQueuePlayer(this._initialState);

  @override
  AudioState build() => _initialState;

  void setQueueState(QueueSlice queue) {
    state = state.copyWith(queue: queue);
  }
}
