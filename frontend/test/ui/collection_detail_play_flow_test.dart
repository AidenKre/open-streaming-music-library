// Phase 6A.2 exit proof (6-P01, 6-P04 unit halves): on a real album detail
// page, a double tap during busy submits once, busy clears after a failure
// with Retry, and over the real LibraryActions + PlaybackRequests +
// ClickRecorder an accepted Play records one album click while a rejected
// one records none.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/tracks_page.dart';

import '../helpers/no_server_api.dart';
import '../helpers/run_async_until.dart';
import '../helpers/server_binding.dart';
import 'browse_harness.dart';
import 'collection_playback_harness.dart';
import 'fake_library_actions.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;

/// Play and Shuffle wait for [gate], then answer [next].
class _GatedActions extends FakeLibraryActions {
  Completer<void> gate = Completer<void>();
  PlaybackOutcome next = const Accepted(1);

  Future<PlaybackOutcome> _answer(String call) async {
    calls.add(call);
    await gate.future;
    return next;
  }

  @override
  Future<PlaybackOutcome> play(LibraryScope collection) =>
      _answer('play ${FakeLibraryActions.describe(collection)}');

  @override
  Future<PlaybackOutcome> shuffle(LibraryScope collection) =>
      _answer('shuffle ${FakeLibraryActions.describe(collection)}');
}

/// The first queue creation fails (a repository write error); later ones
/// succeed.
class _FailFirstCreate extends QueueRepository {
  _FailFirstCreate(super.db);
  var failures = 1;

  @override
  Future<int> createSessionFromExplicitList({
    required String sourceType,
    int? sourceArtistId,
    int? sourceAlbumId,
    required List<String> trackUuids,
    int currentIndex = 0,
    String repeatMode = 'off',
    bool shuffleEnabled = false,
    bool activate = true,
    List<int>? playOrder,
  }) {
    if (failures > 0) {
      failures--;
      return Future.error(Exception('disk I/O error'));
    }
    return super.createSessionFromExplicitList(
      sourceType: sourceType,
      sourceArtistId: sourceArtistId,
      sourceAlbumId: sourceAlbumId,
      trackUuids: trackUuids,
      currentIndex: currentIndex,
      repeatMode: repeatMode,
      shuffleEnabled: shuffleEnabled,
      activate: activate,
      playOrder: playOrder,
    );
  }
}

void main() {
  late AppDatabase db;
  late Directory dir;
  late LocalCoverArtStore covers;

  const seed = [
    SeedTrack(uuid: 'k1', title: 'Kite One', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'Air', trackNumber: 1),
    SeedTrack(uuid: 'k2', title: 'Kite Two', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'Air', trackNumber: 2),
  ];
  const page = TracksPage.album(AlbumScope(artistId: 1, albumId: 2));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, seed);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    dir = await Directory.systemTemp.createTemp('collection-play-flow');
    covers = await LocalCoverArtStore.create(
      directoryProvider: () async => dir,
      apiClient: noServerApi(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  void expectEnabled(WidgetTester tester, String label, bool enabled) {
    expect(tester.getSemantics(find.bySemanticsLabel(label)),
        isSemantics(isButton: true, isEnabled: enabled));
  }

  group('busy on the page (fake LibraryActions)', () {
    late _GatedActions actions;

    Future<void> pump(WidgetTester tester) async {
      actions = _GatedActions();
      await tester.pumpWidget(collectionPlaybackScope(
        db: db,
        covers: covers,
        dir: dir,
        player: CollectionPlayer(null),
        child: page,
        overrides: [libraryActionsProvider.overrideWithValue(actions)],
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a double tap on Play, then Shuffle, while busy submits once',
        (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Play album'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Play album'),
          warnIfMissed: false);
      await tester.tap(find.bySemanticsLabel('Shuffle album'),
          warnIfMissed: false);
      await tester.pump();
      expect(actions.calls, ['play album(1,2)']);
      expectEnabled(tester, 'Play album', false);
      actions.gate.complete();
      await tester.pumpAndSettle();
      expectEnabled(tester, 'Play album', true);
      await teardownTree(tester);
    });

    testWidgets('busy clears after a failure, with Retry', (tester) async {
      await pump(tester);
      actions.next = Failed(StateError('queue creation failed'));
      await tester.tap(find.bySemanticsLabel('Shuffle album'));
      await tester.pump();
      expectEnabled(tester, 'Shuffle album', false);
      actions.gate.complete();
      await tester.pumpAndSettle();
      expectEnabled(tester, 'Play album', true);
      expectEnabled(tester, 'Shuffle album', true);
      expect(find.text("Couldn't start playback."), findsOneWidget);
      actions.next = const Accepted(2);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['shuffle album(1,2)', 'shuffle album(1,2)']);
      expect(find.text("Couldn't start playback."), findsNothing);
      await teardownTree(tester);
    });
  });

  group('the real path', () {
    for (final sessionId in <int?>[7, null]) {
      final queue = sessionId == null ? 'no queue' : 'a queue';
      testWidgets('an accepted Play with $queue records one album click',
          (tester) async {
        final player = CollectionPlayer(sessionId);
        await tester.pumpWidget(collectionPlaybackScope(
            db: db, covers: covers, dir: dir, player: player, child: page));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('Play album'));
        await runAsyncUntil(tester, () => clickRecorded(db),
            reason: 'the accepted Play records its click');
        await tester.pumpAndSettle();
        expect(player.activated, hasLength(1));
        expect(clickSpy(tester).submitted, hasLength(1));
        expect(await recordedClicks(tester, db), [('album', 'srv-1:2')]);
        expect(find.text("Couldn't start playback."), findsNothing);
        await teardownTree(tester);
      });
    }

    // 6-R2-11b (6-P04): the queue creation itself fails on the real path.
    testWidgets('a failed queue creation: the page clears busy, explains, '
        'offers Retry and records no click; Retry then plays', (tester) async {
      final player = CollectionPlayer(7);
      await tester.pumpWidget(collectionPlaybackScope(
        db: db,
        covers: covers,
        dir: dir,
        player: player,
        child: page,
        overrides: [
          queueRepositoryProvider.overrideWith((ref) => _FailFirstCreate(db)),
        ],
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Play album'));
      await runAsyncUntil(
          tester,
          () => find.text("Couldn't start playback.").evaluate().isNotEmpty,
          reason: 'the failure is explained');
      await tester.pumpAndSettle();
      expect(find.text("Couldn't start playback."), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expectEnabled(tester, 'Play album', true);
      expectEnabled(tester, 'Shuffle album', true);
      expect(player.activated, isEmpty);
      expect(clickSpy(tester).submitted, isEmpty);
      expect(await recordedClicks(tester, db), isEmpty);

      await tester.tap(find.text('Retry'));
      await runAsyncUntil(tester, () => clickRecorded(db),
          reason: 'the Retry plays and records its click');
      await tester.pumpAndSettle();
      expect(find.text("Couldn't start playback."), findsNothing);
      expect(player.activated, hasLength(1));
      expect(clickSpy(tester).submitted, hasLength(1));
      expect(await recordedClicks(tester, db), [('album', 'srv-1:2')]);
      await teardownTree(tester);
    });

    testWidgets('offline, an album whose downloads this device can not play '
        'is explained and records no click', (tester) async {
      await tester.runAsync(() async {
        for (final uuid in ['k1', 'k2']) {
          await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
              .write(TracksCompanion(
            filePath: Value('/dl/$uuid.flac'),
            downloadedAtRevision: const Value(1),
            downloadedCodec: const Value('flac'),
          ));
        }
      });
      final player = CollectionPlayer(7);
      await tester.pumpWidget(collectionPlaybackScope(
        db: db,
        covers: covers,
        dir: dir,
        player: player,
        child: page,
        offline: true,
        overrides: [
          codecSupportProvider
              .overrideWithValue(const CodecSupport({AudioCodecFamily.mp3})),
          playbackTargetResolverProvider.overrideWith((ref) =>
              PlaybackTargetResolver(ref.read(queueRepositoryProvider),
                  fileExists: (_) async => true,
                  localSources: ref.read(localSourcePolicyProvider))),
        ],
      ));
      await tester.pumpAndSettle();
      expectEnabled(tester, 'Play album', true); // counts know no codec (O2)
      await tester.tap(find.bySemanticsLabel('Play album'));
      await runAsyncUntil(
          tester,
          () => find.text('Nothing here plays offline.').evaluate().isNotEmpty,
          reason: 'the refusal is explained');
      await tester.pumpAndSettle();
      expect(find.text('Nothing here plays offline.'), findsOneWidget);
      // Pre-merge A6-03: a retry would get the same answer, so none is
      // offered (this expected Retry before).
      expect(find.text('Retry'), findsNothing);
      expect(player.activated, isEmpty);
      expect(clickSpy(tester).submitted, isEmpty);
      expect(await recordedClicks(tester, db), isEmpty);
      await teardownTree(tester);
    });
  });
}
