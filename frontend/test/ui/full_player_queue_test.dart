import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/full_player.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = QueueRepository(db);
  });

  tearDown(() async {
    await db.close();
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
          audioProvider.overrideWith(
            () => _TestQueueAudioCoordinator(
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
          audioProvider.overrideWith(
            () => _TestQueueAudioCoordinator(
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
      final notifier = _MutableTestQueueAudioCoordinator(
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
          audioProvider.overrideWith(() => notifier),
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

  group('cover art', () {
    setUpAll(() {
      ApiClient.init('http://localhost:8000');
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
          audioProvider.overrideWith(
            () => _TestQueueAudioCoordinator(
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
        expect(find.byType(CachedNetworkImage), findsNothing);
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
        expect(find.byType(CachedNetworkImage), findsOneWidget);
      },
    );
  });
}

Future<void> _seedQueueTracks(AppDatabase db, List<String> uuids) async {
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
      duration: const Duration(minutes: 3),
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

class _TestQueueAudioCoordinator extends AudioCoordinator {
  final AudioState _initialState;

  _TestQueueAudioCoordinator(this._initialState);

  @override
  AudioState build() => _initialState;
}

class _MutableTestQueueAudioCoordinator extends AudioCoordinator {
  final AudioState _initialState;

  _MutableTestQueueAudioCoordinator(this._initialState);

  @override
  AudioState build() => _initialState;

  void setQueueState(QueueSlice queue) {
    state = state.copyWith(queue: queue);
  }
}
