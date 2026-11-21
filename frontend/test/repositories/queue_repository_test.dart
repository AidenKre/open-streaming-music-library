import 'dart:math' show Random;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import '../helpers/server_binding.dart';
import '../helpers/library_fixture.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late LibraryFixture fixture;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    repo = QueueRepository(db);
    fixture = LibraryFixture(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'createSessionFromQuery uses canonical order when shuffle is off',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd', 'e'],
      );

      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 1,
        sourceAlbumId: 1,
        currentUuid: 'c',
        orderBy: [OrderParameter(column: 'track_number')],
      );

      final snapshot = await repo.getSessionSnapshot(sessionId);
      final entries = await repo.getPlaybackEntries(sessionId);

      expect(snapshot, isNotNull);
      expect(snapshot!.totalCount, 5);
      expect(snapshot.currentItem?.uuidId, 'c');
      expect(entries.map((entry) => entry.uuidId), ['a', 'b', 'c', 'd', 'e']);
      expect(entries.map((entry) => entry.playPosition), [0, 1, 2, 3, 4]);
      expect(entries.map((entry) => entry.canonicalPosition), [0, 1, 2, 3, 4]);
      expect(await _playOrderCount(db, sessionId), 5);
    },
  );

  test(
    'createSessionFromExplicitList preserves duplicates and current index',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'a', 'c'],
        currentIndex: 2,
      );

      final snapshot = await repo.getSessionSnapshot(sessionId);
      final tracks = await repo.getSessionTracksInPlayOrder(sessionId);

      expect(snapshot?.totalCount, 4);
      expect(snapshot?.currentItem?.playPosition, 2);
      expect(tracks.map((entry) => entry.uuidId), ['a', 'b', 'a', 'c']);
      expect(tracks.map((entry) => entry.itemId).toSet().length, 4);
    },
  );

  test(
    'getSessionSnapshot falls back to first entry when current_item_id is null',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c'],
        currentIndex: 1,
      );

      await db.customStatement(
        'UPDATE queue_sessions SET current_item_id = NULL WHERE id = ?',
        [sessionId],
      );

      final snapshot = await repo.getSessionSnapshot(sessionId);
      expect(snapshot!.totalCount, 3);
      expect(snapshot.currentItem, isNotNull);
      expect(snapshot.currentItem!.uuidId, 'a');
    },
  );

  test(
    'getSessionSnapshot recovers when current_item_id points at a deleted track',
    () async {
      // 8-fix-r1 U20-B-01 (deliberately strengthened, was: current at index
      // 0, where the first and the next survivor are the same entry): the
      // current item is in the middle, so the landing tells them apart.
      await fixture.insertSingles(['a', 'b', 'c']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c'],
        currentIndex: 1,
      );

      // Drop the current track's row (as a tombstone sync would). The INNER
      // JOIN on tracks then resolves current_item_id to null; the snapshot must
      // recover to the next surviving entry rather than returning null or
      // restarting from the first.
      await db.customStatement("DELETE FROM tracks WHERE uuid_id = 'b'");

      final entry = await repo.getFirstPlayableEntry(sessionId);
      expect(entry!.uuidId, 'a');

      final snapshot = await repo.getSessionSnapshot(sessionId);
      expect(snapshot!.currentItem, isNotNull);
      expect(snapshot.currentItem!.uuidId, 'c');
    },
  );

  // 8-fix-r1 U20-B-01 (coordinator decision, logged major deviation): a sync
  // removal of a session's current item lands on the next surviving entry in
  // play order (shuffle order when shuffled; a run of removed entries is
  // skipped); only repeat-all wraps to the first survivor; at the end
  // otherwise the session rests on the last survivor and is reported ended,
  // so the player stops there instead of restarting the queue.
  group('U20-B-01: a removed current item lands on the next survivor', () {
    Future<String?> currentUuid(int sessionId) async {
      final row = await db.customSelect(
        'SELECT qsi.uuid_id AS u FROM queue_sessions AS s '
        'LEFT JOIN queue_session_items AS qsi '
        'ON qsi.item_id = s.current_item_id WHERE s.id = ?',
        variables: [Variable.withInt(sessionId)],
      ).getSingle();
      return row.read<String?>('u');
    }

    Future<int> positionMsOf(int sessionId) async =>
        (await (db.select(db.queueSessions)
                  ..where((s) => s.id.equals(sessionId)))
                .getSingle())
            .currentPositionMs;

    Future<int> session(List<String> uuids, String current,
        {String repeat = 'off'}) async {
      final id = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: uuids,
        currentIndex: uuids.indexOf(current),
        repeatMode: repeat,
      );
      final item = (await repo.getSessionTracksInPlayOrder(id))
          .firstWhere((e) => e.uuidId == current)
          .itemId;
      await repo.updatePlaybackCursor(
          sessionId: id, currentItemId: item, positionMs: 45000);
      return id;
    }

    test('in the middle: the next entry, at its start', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final id = await session(['a', 'b', 'c', 'd'], 'b');

      final result = await repo.removeTrackUuidsFromQueues(const ['b']);

      expect(await currentUuid(id), 'c');
      expect(await positionMsOf(id), 0);
      expect(result.affectedSessionIds, {id});
      expect(result.endedSessionIds, isEmpty);
    });

    test('a run of removed entries is skipped', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final id = await session(['a', 'b', 'c', 'd'], 'b');

      final result = await repo.removeTrackUuidsFromQueues(const ['b', 'c']);

      expect(await currentUuid(id), 'd');
      expect(result.endedSessionIds, isEmpty);
    });

    test('the last entry under repeat-all wraps to the first survivor',
        () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final id = await session(['a', 'b', 'c', 'd'], 'c', repeat: 'all');

      final result =
          await repo.removeTrackUuidsFromQueues(const ['a', 'c', 'd']);

      expect(await currentUuid(id), 'b');
      expect(result.endedSessionIds, isEmpty);
    });

    test('the last entry with repeat off: rests on the last survivor, ended',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final id = await session(['a', 'b', 'c'], 'c');

      final result = await repo.removeTrackUuidsFromQueues(const ['c']);

      expect(await currentUuid(id), 'b',
          reason: 'the end of the queue, not its first entry');
      expect(await positionMsOf(id), 0);
      expect(result.endedSessionIds, {id});
    });

    test('the current and every later entry removed, repeat off: ended on '
        'the last survivor before them', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
      final id = await session(['a', 'b', 'c', 'd', 'e'], 'c');

      final result =
          await repo.removeTrackUuidsFromQueues(const ['a', 'c', 'd', 'e']);

      expect(await currentUuid(id), 'b');
      expect(result.endedSessionIds, {id});
    });

    test('repeat-one: the next entry in the middle; ended at the end',
        () async {
      await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);
      final middle = await session(['a', 'b', 'c'], 'b', repeat: 'one');
      final last = await session(['x', 'y'], 'y', repeat: 'one');

      final result = await repo.removeTrackUuidsFromQueues(const ['b', 'y']);

      expect(await currentUuid(middle), 'c');
      expect(await currentUuid(last), 'x');
      expect(result.endedSessionIds, {last});
    });

    test('shuffled: the next entry of the shuffled play order', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
      // Play order e, b, d, a, c; canonical next of b would be c, the first
      // survivor e.
      final id = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c', 'd', 'e'],
        shuffleEnabled: true,
        playOrder: const [4, 1, 3, 0, 2],
      );
      final b = (await repo.getSessionTracksInPlayOrder(id))
          .firstWhere((e) => e.uuidId == 'b')
          .itemId;
      await repo.updatePlaybackCursor(
          sessionId: id, currentItemId: b, positionMs: 1000);

      await repo.removeTrackUuidsFromQueues(const ['b']);

      expect(await currentUuid(id), 'd');
    });

    test('a removed entry that is not current changes nothing about the '
        'current one', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final id = await session(['a', 'b', 'c'], 'b');

      final result = await repo.removeTrackUuidsFromQueues(const ['c']);

      expect(await currentUuid(id), 'b');
      expect(await positionMsOf(id), 45000);
      expect(result.affectedSessionIds, {id});
      expect(result.endedSessionIds, isEmpty);
    });

    test('every entry removed: no current item, not reported ended (the '
        'player stops an emptied queue)', () async {
      await fixture.insertSingles(['a', 'b']);
      final id = await session(['a', 'b'], 'b');

      final result = await repo.removeTrackUuidsFromQueues(const ['a', 'b']);

      expect(await currentUuid(id), isNull);
      // The row itself, not only the read through the items: a pointer to the
      // deleted item would also read as no current track.
      final row = await (db.select(db.queueSessions)
            ..where((s) => s.id.equals(id)))
          .getSingle();
      expect(row.currentItemId, isNull);
      expect(result.affectedSessionIds, {id});
      expect(result.endedSessionIds, isEmpty);
    });

    // Review r1-fe-a #1: until the player's reconcile runs it still holds
    // the removed item; a cursor save of it must not overwrite the landing.
    test('a cursor save of a removed item keeps the landing', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final id = await session(['a', 'b', 'c'], 'b');
      final removed = (await repo.getSessionTracksInPlayOrder(id))
          .firstWhere((e) => e.uuidId == 'b')
          .itemId;

      await repo.removeTrackUuidsFromQueues(const ['b']);
      await repo.updatePlaybackCursor(
          sessionId: id, currentItemId: removed, positionMs: 50000);

      expect(await currentUuid(id), 'c');
      expect(await positionMsOf(id), 0);
    });

    // Review r1-fe-a #3: a current item without a play-order row is still
    // cleared (as before), not left pointing at a deleted item.
    test('a removed current without a play-order row is cleared', () async {
      await fixture.insertSingles(['a', 'b']);
      final id = await session(['a', 'b'], 'b');
      final b = (await repo.getSessionTracksInPlayOrder(id))
          .firstWhere((e) => e.uuidId == 'b')
          .itemId;
      await db.customStatement(
          'DELETE FROM queue_session_play_order WHERE item_id = ?', [b]);

      final result = await repo.removeTrackUuidsFromQueues(const ['b']);

      final row = await (db.select(db.queueSessions)
            ..where((s) => s.id.equals(id)))
          .getSingle();
      expect(row.currentItemId, isNull);
      expect(result.endedSessionIds, isEmpty);
    });

    test('each affected session lands by its own order', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);
      // An earlier session, inactive once the next one activates (not a
      // prepared one: those keep their refusal, see the 6A.1b group).
      final second = await repo.createSessionFromExplicitList(
          sourceType: 'search',
          trackUuids: const ['x', 'b', 'y', 'a'],
          currentIndex: 1);
      final first = await session(['a', 'b', 'c'], 'b');

      await repo.removeTrackUuidsFromQueues(const ['b']);

      expect(await currentUuid(first), 'c');
      expect(await currentUuid(second), 'y');
    });
  });

  test(
    'replacePlayOrder changes effective order without rewriting canonical order',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd'],
      );

      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 1,
        sourceAlbumId: 1,
        currentUuid: 'b',
        orderBy: [OrderParameter(column: 'track_number')],
      );

      final canonicalBefore = await repo.getCanonicalItemIds(sessionId);
      final shuffled = [
        canonicalBefore[0],
        canonicalBefore[1],
        canonicalBefore[3],
        canonicalBefore[2],
      ];

      await repo.replacePlayOrder(sessionId, shuffled);
      await repo.updateShuffleEnabled(sessionId, true);

      final playOrder = await repo.getSessionTracksInPlayOrder(sessionId);
      final canonicalAfter = await repo.getCanonicalItemIds(sessionId);

      expect(playOrder.map((entry) => entry.uuidId), ['a', 'b', 'd', 'c']);
      expect(canonicalAfter, canonicalBefore);
    },
  );

  test('clearing play order falls back to canonical order', () async {
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Album',
      uuids: ['a', 'b', 'c', 'd'],
    );
    await fixture.insertSingles(['x']);

    final sessionId = await repo.createSessionFromQuery(
      sourceType: 'album',
      sourceArtistId: 1,
      sourceAlbumId: 1,
      currentUuid: 'b',
      orderBy: [OrderParameter(column: 'track_number')],
    );

    final snapshot = await repo.getSessionSnapshot(sessionId);
    final currentItemId = snapshot!.currentItem!.itemId;

    await repo.prependManualItems(sessionId, const ['x']);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: await repo.getFutureMainItemIds(
        sessionId,
        currentItemId: currentItemId,
        usePlayOrder: false,
      ),
    );

    final queued = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(queued.map((entry) => entry.uuidId), ['a', 'b', 'x', 'c', 'd']);

    final futureMainIds = await repo.getFutureMainItemIds(
      sessionId,
      currentItemId: currentItemId,
      usePlayOrder: false,
    );
    await repo.updateShuffleEnabled(sessionId, true);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: futureMainIds.reversed.toList(growable: false),
    );

    final shuffled = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(shuffled.map((entry) => entry.uuidId), ['a', 'b', 'x', 'd', 'c']);

    await repo.updateShuffleEnabled(sessionId, false);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: await repo.getFutureMainItemIds(
        sessionId,
        currentItemId: currentItemId,
        usePlayOrder: false,
      ),
    );

    final restored = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(restored.map((entry) => entry.uuidId), ['a', 'b', 'x', 'c', 'd']);
    expect(await _playOrderCount(db, sessionId), 5);
  });

  test('prependManualItems inserts ahead of the main future', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 1,
    );
    final current = (await repo.getSessionSnapshot(sessionId))!.currentItem!;

    await repo.prependManualItems(sessionId, const ['x', 'y']);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: current.itemId,
      mainFutureItemIds: await repo.getFutureMainItemIds(
        sessionId,
        currentItemId: current.itemId,
        usePlayOrder: false,
      ),
    );

    final entries = await repo.getSessionTracksInPlayOrder(sessionId);

    expect(entries.map((entry) => entry.uuidId), ['a', 'b', 'x', 'y', 'c']);
    expect(entries.map((entry) => entry.playPosition), [0, 1, 2, 3, 4]);
    expect(
      entries
          .where((entry) => entry.queueType == QueueItemTypes.manual)
          .map((entry) => entry.canonicalPosition),
      [0, 1],
    );
  });

  test('removeItem shifts canonical and play positions safely', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b', 'c', 'd'],
      currentIndex: 2,
    );

    final entries = await repo.getPlaybackEntries(sessionId);
    await repo.removeItem(sessionId, entries[1].itemId);

    final updated = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(updated.map((entry) => entry.uuidId), ['a', 'c', 'd']);
    expect(updated.map((entry) => entry.canonicalPosition), [0, 1, 2]);
    expect(updated.map((entry) => entry.playPosition), [0, 1, 2]);
  });

  test(
    'getPlaybackEntriesForItemIds returns updated play positions after shuffle',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'custom',
        trackUuids: const ['a', 'b', 'c', 'd'],
        currentIndex: 0,
      );

      final entries = await repo.getPlaybackEntries(sessionId);
      await repo.replacePlayOrder(sessionId, [
        entries[2].itemId,
        entries[0].itemId,
        entries[3].itemId,
        entries[1].itemId,
      ]);
      await repo.updateShuffleEnabled(sessionId, true);

      final updated = await repo.getPlaybackEntriesForItemIds(
        sessionId,
        entries.map((entry) => entry.itemId),
      );

      final byUuid = {
        for (final entry in updated) entry.uuidId: entry.playPosition,
      };
      expect(byUuid, {'a': 1, 'b': 3, 'c': 0, 'd': 2});
    },
  );

  test('appendManualItems creates play order entries immediately', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 0,
    );

    final beforeCount = await _playOrderCount(db, sessionId);
    expect(beforeCount, 3);

    await repo.appendManualItems(sessionId, const ['x', 'y']);

    final afterCount = await _playOrderCount(db, sessionId);
    expect(afterCount, 5);

    final manualIds = await repo.getQueueTypeItemIds(
      sessionId,
      QueueItemTypes.manual,
    );
    expect(manualIds, hasLength(2));
  });

  test('prependManualItems creates play order entries immediately', () async {
    await fixture.insertSingles(['a', 'b', 'x']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b'],
      currentIndex: 0,
    );

    await repo.prependManualItems(sessionId, const ['x']);

    final afterCount = await _playOrderCount(db, sessionId);
    expect(afterCount, 3);
  });

  test('createSessionFromQuery with no matching tracks throws', () async {
    expect(
      () => repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 999,
        sourceAlbumId: 999,
        currentUuid: 'nonexistent',
        orderBy: [OrderParameter(column: 'track_number')],
      ),
      throwsStateError,
    );
  });

  test(
    'createSessionFromQuery with downloadedOnly only inserts downloaded tracks',
    () async {
      // Two downloaded, three streaming-only.
      await fixture.insertSingles(['dl-1', 'stream-1', 'dl-2', 'stream-2', 'stream-3']);
      for (final uuid in const ['dl-1', 'dl-2']) {
        await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .write(TracksCompanion(filePath: Value('/tmp/$uuid.audio')));
      }

      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'library',
        currentUuid: 'dl-1',
        orderBy: [OrderParameter(column: 'uuid_id')],
        downloadedOnly: true,
      );

      final entries = await repo.getPlaybackEntries(sessionId);
      expect(entries.map((e) => e.uuidId), ['dl-1', 'dl-2']);
    },
  );

  // Phase 5 decision 6 (2026-11-09): a damaged download keeps file_path,
  // but it is not a usable download.
  test('a damaged download is no local source and no Downloaded-only track',
      () async {
    await fixture.insertSingles(['dl', 'damaged']);
    for (final uuid in const ['dl', 'damaged']) {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(filePath: Value('/tmp/$uuid.audio')));
    }
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('damaged')))
        .write(const TracksCompanion(
            damagedFilePath: Value('/tmp/damaged.audio')));

    final all = await repo.createSessionFromQuery(
      sourceType: 'library',
      currentUuid: 'dl',
      orderBy: [OrderParameter(column: 'uuid_id')],
    );
    final entries = await repo.getPlaybackEntries(all);
    expect(entries.map((e) => (e.uuidId, e.filePath)),
        [('damaged', null), ('dl', '/tmp/dl.audio')]);
    final damagedItem = entries.first.itemId;
    expect((await repo.getPlaybackEntryForItem(all, damagedItem))!.filePath,
        isNull);
    expect(
        (await repo.getPlaybackEntriesForItemIds(all, [damagedItem]))
            .single
            .filePath,
        isNull);

    final downloaded = await repo.createSessionFromQuery(
      sourceType: 'library',
      currentUuid: 'dl',
      orderBy: [OrderParameter(column: 'uuid_id')],
      downloadedOnly: true,
    );
    expect((await repo.getPlaybackEntries(downloaded)).map((e) => e.uuidId),
        ['dl']);
  });

  // Review major 1: entries carry the codecs the playback policy checks.
  test('playback entries carry the download and source codecs', () async {
    await fixture.insertSingles(['a', 'b']);
    await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
        .write(const TrackmetadataCompanion(codec: Value('flac')));
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
        .write(const TracksCompanion(
            filePath: Value('/tmp/a.m4a'), downloadedCodec: Value('aac')));
    final session = await repo.createSessionFromQuery(
      sourceType: 'library',
      currentUuid: 'a',
      orderBy: [OrderParameter(column: 'uuid_id')],
    );
    final entries = await repo.getPlaybackEntries(session);
    expect(entries.map((e) => (e.uuidId, e.downloadedCodec, e.sourceCodec)),
        [('a', 'aac', 'flac'), ('b', null, null)]);
    expect(
        (await repo.getPlaybackEntryForItem(session, entries.first.itemId))!
            .sourceCodec,
        'flac');
  });

  group('locally playable lookup', () {
    ({QueueRepository store, PlaybackTargetResolver resolver}) repoWithFs(Set<String> existing) {
      final store = QueueRepository(db);
      return (store: store, resolver: PlaybackTargetResolver(store, fileExists: (path) async => existing.contains(path)));
    }

    Future<void> markDownloaded(String uuid, String path) async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(filePath: Value(path)));
    }

    test(
      'findNextLocallyPlayableEntry skips streaming-only entries forward',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/tmp/a');
        await markDownloaded('d', '/tmp/d');
        final existing = {'/tmp/a', '/tmp/d'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.store.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          currentIndex: 0,
        );

        final next = await localRepo.resolver.resolveAdvance(offline: true,
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'off',
          totalCount: 5,
        );

        expect(next.target?.entry.uuidId, 'd');
      },
    );

    test(
      'findNextLocallyPlayableEntry searches backward when going to previous',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/tmp/a');
        await markDownloaded('e', '/tmp/e');
        final existing = {'/tmp/a', '/tmp/e'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.store.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          currentIndex: 4,
        );

        final prev = await localRepo.resolver.resolveAdvance(offline: true,
          sessionId: sessionId,
          fromPlayPosition: 4,
          direction: PlayOrderDirection.backward,
          repeatMode: 'off',
          totalCount: 5,
        );

        expect(prev.target?.entry.uuidId, 'a');
      },
    );

    test(
      'findNextLocallyPlayableEntry wraps when repeat mode is all',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/tmp/a');
        final existing = {'/tmp/a'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.store.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c'],
          currentIndex: 0,
        );

        final wrapped = await localRepo.resolver.resolveAdvance(offline: true,
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'all',
          totalCount: 3,
        );

        expect(wrapped.target?.entry.uuidId, 'a');
      },
    );

    test(
      'findNextLocallyPlayableEntry returns null when nothing is playable',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);

        final localRepo = repoWithFs(const <String>{});
        final sessionId = await localRepo.store.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c'],
          currentIndex: 0,
        );

        final result = await localRepo.resolver.resolveAdvance(offline: true,
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'all',
          totalCount: 3,
        );

        expect(result.target, isNull);
      },
    );

    test(
      'findNextLocallyPlayableEntry treats a db-only file_path as not playable',
      () async {
        await fixture.insertSingles(['a', 'b']);
        await markDownloaded('a', '/tmp/missing');
        await markDownloaded('b', '/tmp/present');

        final localRepo = repoWithFs({'/tmp/present'});
        final sessionId = await localRepo.store.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b'],
          currentIndex: 0,
        );

        final result = await localRepo.resolver.resolveAdvance(offline: true,
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'off',
          totalCount: 2,
          includeStart: true,
        );

        expect(result.target?.entry.uuidId, 'b');
      },
    );

    test('findLocallyPlayableFallback returns requested when playable', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await markDownloaded('b', '/tmp/b');
      final existing = {'/tmp/b'};

      final localRepo = repoWithFs(existing);
      final sessionId = await localRepo.store.createSessionFromExplicitList(
        sourceType: 'custom',
        trackUuids: const ['a', 'b', 'c'],
        currentIndex: 1,
      );
      final preferred = (await localRepo.store.getSessionSnapshot(sessionId))!
          .currentItem!;

      final result = await localRepo.resolver.resolveStart(offline: true,
        sessionId: sessionId,
        preferredItemId: preferred.itemId,
        totalCount: 3,
      );

      expect(result.target?.entry.uuidId, 'b');
    });

    test(
      'findLocallyPlayableFallback picks nearest playable when requested missing',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/tmp/a');
        await markDownloaded('e', '/tmp/e');
        final existing = {'/tmp/a', '/tmp/e'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.store.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          currentIndex: 2,
        );
        final preferred = (await localRepo.store.getSessionSnapshot(sessionId))!
            .currentItem!;

        final result = await localRepo.resolver.resolveStart(offline: true,
          sessionId: sessionId,
          preferredItemId: preferred.itemId,
          totalCount: 5,
        );

        expect(result.target?.entry.uuidId, 'e');
      },
    );
  });

  test(
    'getSessionTracksPage returns a bounded page in effective order',
    () async {
      await fixture.insertSingles(List.generate(12, (i) => 'track-${i + 1}'));

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'custom',
        trackUuids: List.generate(12, (i) => 'track-${i + 1}'),
        currentIndex: 5,
      );
      final entries = await repo.getPlaybackEntries(sessionId);
      await repo.replacePlayOrder(sessionId, [
        entries[5].itemId,
        entries[2].itemId,
        entries[8].itemId,
        entries[0].itemId,
        entries[1].itemId,
        entries[3].itemId,
        entries[4].itemId,
        entries[6].itemId,
        entries[7].itemId,
        entries[9].itemId,
        entries[10].itemId,
        entries[11].itemId,
      ]);
      await repo.updateShuffleEnabled(sessionId, true);

      final page = await repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: 2,
        limit: 4,
      );

      expect(page, hasLength(4));
      expect(page.first.playPosition, 2);
      expect(page.last.playPosition, 5);
      expect(page.map((entry) => entry.uuidId), [
        'track-9',
        'track-1',
        'track-2',
        'track-4',
      ]);
    },
  );

  group('5B.1 (SC-05/SC-27): prepared sessions', () {
    Future<QueueSession?> active() => repo.getActiveSession();

    test('preparing a session leaves the active one untouched', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final current = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a', 'b']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['c'], activate: false);
      expect((await active())?.id, current);
      final snapshot = await repo.getSessionSnapshot(prepared);
      expect(snapshot?.session.isActive, isFalse);
      expect(snapshot?.currentItem?.uuidId, 'c');
      final query = await repo.createSessionFromQuery(
          sourceType: 'library', currentUuid: 'b', activate: false);
      expect((await active())?.id, current);
      expect((await repo.getSessionSnapshot(query))?.session.isActive, isFalse);
    });

    test('activating a prepared session makes it the only active one',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final current = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['b'], activate: false);
      await repo.activateSession(prepared);
      expect((await active())?.id, prepared);
      expect((await repo.getSessionSnapshot(current))?.session.isActive,
          isFalse);
    });

    test('activating a session that is gone fails and changes nothing',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final current = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['b'], activate: false);
      await repo.discardSession(prepared);
      await expectLater(repo.activateSession(prepared), throwsStateError);
      expect((await active())?.id, current);
    });

    test('discarding removes a prepared session, never the active one',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final current = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['b'], activate: false);
      expect(await repo.discardSession(prepared), isTrue);
      expect(await repo.getSessionSnapshot(prepared), isNull);
      expect(await _playOrderCount(db, prepared), 0);
      expect(await repo.discardSession(current), isFalse);
      expect((await active())?.id, current);
    });

    test('startup pruning deletes every inactive session', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final first = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a']);
      final current = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['b']); // deactivates first
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['c'], activate: false);
      expect(await repo.pruneInactiveSessions(), 2);
      expect(await repo.getSessionSnapshot(first), isNull);
      expect(await repo.getSessionSnapshot(prepared), isNull);
      expect((await active())?.id, current);
    });
  });

  group('6A.1b: the explicit-list prepare takes a permutation (D2)', () {
    test('the permutation is the play order from position zero; the first '
        'entry is current', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
      for (var run = 0; run < 5; run++) {
        final sessionId = await repo.createSessionFromExplicitList(
          sourceType: 'album',
          sourceArtistId: 7,
          sourceAlbumId: 9,
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          playOrder: const [4, 0, 3, 1, 2],
          shuffleEnabled: true,
          repeatMode: 'all',
          activate: false,
        );

        expect(await _orderRows(db, sessionId), [
          (0, 4, 'e'),
          (1, 0, 'a'),
          (2, 3, 'd'),
          (3, 1, 'b'),
          (4, 2, 'c'),
        ], reason: 'run $run: written as given, never reshuffled');
        final snapshot = (await repo.getSessionSnapshot(sessionId))!;
        expect(snapshot.currentItem?.uuidId, 'e');
        expect(snapshot.currentItem?.playPosition, 0);
        // 6-R1-10: resume_main_item_id is never written.
        expect(snapshot.session.resumeMainItemId, isNull);
        expect(snapshot.session.shuffleEnabled, isTrue);
        expect(snapshot.session.repeatMode, 'all');
        expect(snapshot.session.isActive, isFalse);
        expect(snapshot.session.sourceType, 'album');
        expect(snapshot.session.sourceArtistId, 7);
        expect(snapshot.session.sourceAlbumId, 9);
      }
    });

    test('duplicate tracks keep one entry per canonical position', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'album',
        trackUuids: const ['a', 'b', 'a', 'c'],
        playOrder: const [2, 0, 3, 1],
        shuffleEnabled: true,
      );
      expect(await _orderRows(db, sessionId), [
        (0, 2, 'a'),
        (1, 0, 'a'),
        (2, 3, 'c'),
        (3, 1, 'b'),
      ]);
      expect((await repo.getSessionSnapshot(sessionId))!.currentItem
          ?.canonicalPosition, 2);
    });

    test('an invalid permutation is refused and writes nothing', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      for (final bad in const [
        [0, 0, 1],
        [0, 1],
        [0, 1, 2, 2],
        [0, 1, 3],
        [-1, 0, 1],
        <int>[],
      ]) {
        await expectLater(
          repo.createSessionFromExplicitList(
            sourceType: 'album',
            trackUuids: const ['a', 'b', 'c'],
            playOrder: bad,
            shuffleEnabled: true,
          ),
          throwsArgumentError,
          reason: '$bad',
        );
      }
      expect(await db.select(db.queueSessions).get(), isEmpty);
      expect(await db.select(db.queueSessionItems).get(), isEmpty);
      expect(await db.select(db.queueSessionPlayOrder).get(), isEmpty);
    });

    test('without a permutation the list keeps its canonical order',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'album',
        trackUuids: const ['a', 'b', 'c'],
      );
      expect(await _orderRows(db, sessionId),
          [(0, 0, 'a'), (1, 1, 'b'), (2, 2, 'c')]);
    });
  });

  group('6A.1b: a prepared session activates only while its current item '
      'is still queued (spec §5 disappearance)', () {
    test('its current item removed: refused, nothing changes', () async {
      await fixture.insertSingles(['x', 'a', 'b']);
      final active = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['x']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'album', trackUuids: const ['a', 'b'], activate: false);
      await repo.removeTrackUuidsFromQueues(const ['a']);

      await expectLater(repo.activateSession(prepared), throwsStateError);
      expect((await repo.getActiveSession())?.id, active);
    });

    test('emptied by removal: refused', () async {
      await fixture.insertSingles(['a', 'b']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'album', trackUuids: const ['a', 'b'], activate: false);
      await repo.removeTrackUuidsFromQueues(const ['a', 'b']);
      await expectLater(repo.activateSession(prepared), throwsStateError);
      expect(await repo.getActiveSession(), isNull);
    });

    test('another member removed: activates', () async {
      await fixture.insertSingles(['a', 'b']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 'album', trackUuids: const ['a', 'b'], activate: false);
      await repo.removeTrackUuidsFromQueues(const ['b']);
      await repo.activateSession(prepared);
      expect((await repo.getActiveSession())?.id, prepared);
    });

    test('review r1 #3: the prepared target is never written to a session '
        'that is not prepared', () async {
      await fixture.insertSingles(['a', 'b']);
      final active = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a', 'b']);
      final second = (await repo.getSessionTracksInPlayOrder(active))[1];
      await expectLater(
          repo.setPreparedCurrentItem(active, second.itemId, 1),
          throwsStateError);
      expect((await repo.getSessionSnapshot(active))!.currentItem?.uuidId,
          'a');
    });

    test('a session that was active before is reactivated as today, even '
        'without a current item', () async {
      await fixture.insertSingles(['a', 'b', 'y']);
      final previous = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a', 'b']);
      final next = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['y'], activate: false);
      await repo.activateSession(next);
      // No current item (a removal would land on the next track instead).
      await db.customStatement(
          'UPDATE queue_sessions SET current_item_id = NULL WHERE id = ?',
          [previous]);
      final row = await (db.select(db.queueSessions)
            ..where((s) => s.id.equals(previous)))
          .getSingle();
      expect(row.currentItemId, isNull, reason: 'precondition');
      await repo.activateSession(previous);
      expect((await repo.getActiveSession())?.id, previous);
    });
  });

  test('U20-FE-QUEUE-B-03: rebuilding the future binds no variable per '
      'played item (a long played part stays under SQLite\'s variable limit)',
      () async {
    // The bundled SQLite's limit (32,766 since 3.32; 999 before) is not the
    // test host's, so the bound variables are counted instead.
    final recorder = _VariableCountRecorder();
    final counted = AppDatabase(NativeDatabase.memory().interceptWith(recorder));
    addTearDown(counted.close);
    await seedTestBinding(counted);
    final countedRepo = QueueRepository(counted);
    await LibraryFixture(counted).insertSingles(['a', 'x']);
    final sessionId = await countedRepo.createSessionFromExplicitList(
        sourceType: 'search', trackUuids: const ['a']);
    // 2,000 more main items, played in order.
    const extra = 2000;
    await counted.customStatement(
        'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n '
        'WHERE i < $extra) '
        'INSERT INTO queue_session_items (session_id, queue_type, position, '
        "uuid_id) SELECT $sessionId, 'main', i, 'a' FROM n");
    await counted.customStatement(
        'INSERT INTO queue_session_play_order (session_id, play_position, '
        'item_id) SELECT session_id, position, item_id FROM '
        "queue_session_items WHERE session_id = $sessionId AND position > 0 "
        "AND queue_type = 'main'");
    final last = (await countedRepo.getPlaybackEntries(sessionId,
            startPlayPosition: extra, limit: 1))
        .single;
    await countedRepo.prependManualItems(sessionId, const ['x']);

    recorder.maxArgs = 0;
    await countedRepo.rebuildFutureSuffix(sessionId,
        currentItemId: last.itemId, mainFutureItemIds: const []);

    expect(recorder.maxArgs, lessThan(100),
        reason: 'no statement binds the played part item by item');
    expect(await _playOrderCount(counted, sessionId), extra + 2);
    final tail = await countedRepo.getPlaybackEntries(sessionId,
        startPlayPosition: extra, limit: 5);
    expect(tail, hasLength(2));
    expect(tail.first.itemId, last.itemId);
    expect(tail.last.uuidId, 'x', reason: 'the queued item follows the '
        'current track');
    expect(tail.last.queueType, 'manual');
  });

  group('sticky shuffle draws from the injected generator (U20-FE-QUEUE-A-03)',
      () {
    const uuids = ['a', 'b', 'c', 'd', 'e', 'f'];
    // The futures in canonical order, shuffled by a generator with the
    // same seed: what the repository must produce.
    List<String> expected(int seed) =>
        ['a', 'b', ...['c', 'd', 'e', 'f']..shuffle(Random(seed))];

    for (final seed in [1, 7, 42]) {
      test('seed $seed, both creation paths', () async {
        await fixture.insertSingles(uuids);
        final seeded = QueueRepository(db, random: Random(seed));
        final list = await seeded.createSessionFromExplicitList(
            sourceType: 's', trackUuids: uuids, currentIndex: 1,
            shuffleEnabled: true);
        expect((await _orderRows(db, list)).map((r) => r.$3), expected(seed));
        final again = QueueRepository(db, random: Random(seed));
        final query = await again.createSessionFromQuery(
            sourceType: 'library', currentUuid: 'b', shuffleEnabled: true);
        expect((await _orderRows(db, query)).map((r) => r.$3), expected(seed));
      });
    }

    test('the scope\'s repository uses queueRandomProvider', () async {
      await fixture.insertSingles(uuids);
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        queueRandomProvider.overrideWithValue(Random(7)),
      ]);
      addTearDown(c.dispose);
      final id = await c.read(queueRepositoryProvider).createSessionFromExplicitList(
          sourceType: 's', trackUuids: uuids, currentIndex: 1,
          shuffleEnabled: true);
      expect((await _orderRows(db, id)).map((r) => r.$3), expected(7));
    });
  });

  // Guide 6.4 missing test (U20-FE-QUEUE-A-06): the five position-shift
  // statements keep every session's positions dense and leave other
  // sessions alone, with queued items and a shuffled order.
  test('queue position shifts: two sessions, queued items, a shuffled order',
      () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'w', 'x', 'y', 'z']);
    final other = await repo.createSessionFromExplicitList(
        sourceType: 's', trackUuids: const ['a', 'b', 'c']);
    await repo.prependManualItems(other, const ['y']);
    final s = await repo.createSessionFromExplicitList(
        sourceType: 's', trackUuids: const ['a', 'b', 'c', 'd', 'e'],
        currentIndex: 1, shuffleEnabled: true);

    Future<List<(String, int, String)>> items(int session) async => [
          for (final r in await db.customSelect(
                  'SELECT queue_type, position, uuid_id FROM queue_session_items '
                  'WHERE session_id = ? ORDER BY queue_type, position',
                  variables: [Variable.withInt(session)]).get())
            (r.read<String>('queue_type'), r.read<int>('position'),
                r.read<String>('uuid_id')),
        ];

    // Dense play positions 0..n-1 over exactly the session's items, and
    // dense canonical positions per queue type.
    Future<void> dense(int session, {required String step}) async {
      final order = await _orderRows(db, session);
      final its = await items(session);
      expect(order.map((r) => r.$1), [for (var i = 0; i < its.length; i++) i],
          reason: '$step: play positions of $session');
      for (final type in ['main', 'manual']) {
        final ps = [for (final i in its) if (i.$1 == type) i.$2];
        expect(ps, [for (var i = 0; i < ps.length; i++) i],
            reason: '$step: $type positions of $session');
      }
      expect(order.map((r) => r.$3).toList()..sort(),
          its.map((i) => i.$3).toList()..sort(),
          reason: '$step: the play order holds exactly the items');
    }

    final otherBefore = await _orderRows(db, other);
    final otherItemsBefore = await items(other);
    await dense(s, step: 'start');

    await repo.prependManualItems(s, const ['x', 'y']);
    await repo.prependManualItems(s, const ['z']);
    await repo.appendManualItems(s, const ['w']);
    await dense(s, step: 'queued');
    expect([for (final i in await items(s)) if (i.$1 == 'manual') i.$3],
        ['z', 'x', 'y', 'w'], reason: 'Play next goes first, Add to queue last');

    final xItem = (await repo.getSessionTracksInPlayOrder(s))
        .firstWhere((e) => e.uuidId == 'x');
    final dItem = (await repo.getSessionTracksInPlayOrder(s))
        .firstWhere((e) => e.uuidId == 'd');
    final orderBefore = [for (final r in await _orderRows(db, s)) r.$3];
    await repo.removeItem(s, xItem.itemId);
    await repo.removeItem(s, dItem.itemId);
    await dense(s, step: 'removed');
    expect([for (final r in await _orderRows(db, s)) r.$3],
        [for (final u in orderBefore) if (u != 'x' && u != 'd') u],
        reason: 'the rest keep their relative play order');
    expect(await _orderRows(db, other), otherBefore,
        reason: 'the other session is untouched');
    expect(await items(other), otherItemsBefore);

    await repo.removeTrackUuidsFromQueues(const ['b']);
    await dense(s, step: 'sync removal');
    await dense(other, step: 'sync removal');
    expect([for (final r in await _orderRows(db, other)) r.$3],
        ['a', 'c', 'y']);
    expect(await items(other), [('main', 0, 'a'), ('main', 1, 'c'),
        ('manual', 0, 'y')]);
    expect([for (final i in await items(s)) if (i.$1 == 'main') i.$3],
        ['a', 'c', 'e'], reason: 'canonical order kept');
  });

  group('typed errors (section 6 #6): which refusal is "nothing to queue" '
      'or "gone", and which is not', () {
    test('creation: no track, or the current track not among them: '
        'NothingToQueue', () async {
      await fixture.insertSingles(['a']);
      await expectLater(
          repo.createSessionFromExplicitList(
              sourceType: 's', trackUuids: const []),
          throwsA(isA<NothingToQueue>()));
      await expectLater(
          repo.createSessionFromQuery(
              sourceType: 'library', currentUuid: 'missing'),
          throwsA(isA<NothingToQueue>()));
    });

    test('a prepared session or its target gone: PreparedSessionGone',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final prepared = await repo.createSessionFromExplicitList(
          sourceType: 's', trackUuids: const ['a', 'b'], activate: false);
      final items = await repo.getCanonicalItemIds(prepared);
      await repo.removeTrackUuidsFromQueues(const ['a']);
      await expectLater(repo.setPreparedCurrentItem(prepared, items[0], 0),
          throwsA(isA<PreparedSessionGone>()), reason: 'the target is gone');
      await expectLater(repo.activateSession(prepared),
          throwsA(isA<PreparedSessionGone>()),
          reason: 'its current item is gone');
      await repo.discardSession(prepared);
      await expectLater(repo.activateSession(prepared),
          throwsA(isA<PreparedSessionGone>()), reason: 'the session is gone');
    });

    test('a session this repository did not prepare is an internal error, '
        'not "gone"', () async {
      await fixture.insertSingles(['a']);
      final active = await repo.createSessionFromExplicitList(
          sourceType: 's', trackUuids: const ['a']);
      final items = await repo.getCanonicalItemIds(active);
      await expectLater(
          repo.setPreparedCurrentItem(active, items[0], 0),
          throwsA(predicate((e) => e is StateError && e is! PreparedSessionGone,
              'a plain StateError')));
    });
  });

  test('withoutDownload copies every field except the download path', () {
    const entry = QueuePlaybackEntry(
      itemId: 7,
      queueType: QueueItemTypes.manual,
      canonicalPosition: 3,
      playPosition: 5,
      uuidId: 'u',
      filePath: '/dl/u.flac',
      downloadedCodec: 'flac',
      sourceCodec: 'alac',
    );
    final copy = entry.withoutDownload();
    expect(copy.filePath, isNull);
    expect(
        (copy.itemId, copy.queueType, copy.canonicalPosition,
            copy.playPosition, copy.uuidId, copy.downloadedCodec,
            copy.sourceCodec),
        (7, QueueItemTypes.manual, 3, 5, 'u', 'flac', 'alac'));
  });

  // Characterization before the two creation paths share their ending
  // (refactor U20-FE-QUEUE-A-02): the current item, the sticky-shuffle
  // block and the "prepared" registration behave the same on both.
  group('the two session-creation paths end the same way', () {
    const uuids = ['a', 'b', 'c', 'd', 'e', 'f'];
    final paths = <String,
        Future<int> Function(QueueRepository r,
            {required bool shuffle, required bool activate})>{
      'query': (r, {required shuffle, required activate}) =>
          r.createSessionFromQuery(
              sourceType: 'library',
              currentUuid: 'c',
              shuffleEnabled: shuffle,
              activate: activate),
      'explicit list': (r, {required shuffle, required activate}) =>
          r.createSessionFromExplicitList(
              sourceType: 'search',
              trackUuids: uuids,
              currentIndex: 2,
              shuffleEnabled: shuffle,
              activate: activate),
    };

    for (final MapEntry(key: name, value: create) in paths.entries) {
      test('$name: sticky shuffle keeps the played part and the current '
          'track in place and shuffles only what follows', () async {
        await fixture.insertSingles(uuids);
        // Seeded, so whether some run leaves the future in canonical order
        // is fixed; a set alone would also pass with no shuffle at all.
        final seeded = QueueRepository(db, random: Random(3));
        final tails = <List<String>>[];
        for (var run = 0; run < 5; run++) {
          final id = await create(seeded, shuffle: true, activate: true);
          final rows = await _orderRows(db, id);
          expect(rows.map((r) => r.$1), [0, 1, 2, 3, 4, 5]);
          expect(rows.take(3).map((r) => r.$3), ['a', 'b', 'c']);
          final tail = [for (final r in rows.skip(3)) r.$3];
          expect(tail.toSet(), {'d', 'e', 'f'});
          tails.add(tail);
          final snapshot = (await repo.getSessionSnapshot(id))!;
          expect(snapshot.currentItem?.uuidId, 'c');
          expect(snapshot.currentItem?.playPosition, 2);
          expect(snapshot.session.shuffleEnabled, isTrue);
          expect(snapshot.session.isActive, isTrue);
        }
        expect(tails.any((t) => t.join() != 'def'), isTrue,
            reason: 'what follows the current track is shuffled');
      });

      test('$name: without shuffle the play order is canonical', () async {
        await fixture.insertSingles(uuids);
        final id = await create(repo, shuffle: false, activate: true);
        expect((await _orderRows(db, id)).map((r) => r.$3), uuids);
        expect((await repo.getSessionSnapshot(id))!.currentItem?.uuidId, 'c');
      });

      test('$name: only a session prepared inactive is registered as '
          'prepared', () async {
        await fixture.insertSingles(uuids);
        final prepared = await create(repo, shuffle: false, activate: false);
        final items = await repo.getCanonicalItemIds(prepared);
        await repo.setPreparedCurrentItem(prepared, items[4], 4);
        expect((await repo.getSessionSnapshot(prepared))!.currentItem?.uuidId,
            'e');
        expect((await repo.getSessionSnapshot(prepared))!.session.isActive,
            isFalse);
        final active = await create(repo, shuffle: false, activate: true);
        final activeItems = await repo.getCanonicalItemIds(active);
        await expectLater(
            repo.setPreparedCurrentItem(active, activeItems[4], 4),
            throwsStateError);
        expect((await repo.getSessionSnapshot(active))!.currentItem?.uuidId,
            'c', reason: 'refused: nothing changed');
      });
    }

    test('explicit list with a permutation: only a session prepared '
        'inactive is registered as prepared', () async {
      await fixture.insertSingles(uuids);
      Future<int> create({required bool activate}) =>
          repo.createSessionFromExplicitList(
              sourceType: 'album',
              trackUuids: uuids,
              playOrder: const [5, 4, 3, 2, 1, 0],
              shuffleEnabled: true,
              activate: activate);
      final prepared = await create(activate: false);
      final items = await repo.getCanonicalItemIds(prepared);
      await repo.setPreparedCurrentItem(prepared, items[0], 5);
      final active = await create(activate: true);
      final activeItems = await repo.getCanonicalItemIds(active);
      await expectLater(repo.setPreparedCurrentItem(active, activeItems[0], 5),
          throwsStateError);
    });

    test('explicit list: no tracks is refused and leaves no session',
        () async {
      await expectLater(
          repo.createSessionFromExplicitList(
              sourceType: 'search', trackUuids: const []),
          throwsStateError);
      expect(await db.select(db.queueSessions).get(), isEmpty);
    });

    test('query: a current track that is not in the result is refused and '
        'leaves no session', () async {
      await fixture.insertSingles(uuids);
      await expectLater(
          repo.createSessionFromQuery(
              sourceType: 'library', currentUuid: 'missing'),
          throwsStateError);
      expect(await db.select(db.queueSessions).get(), isEmpty);
      expect(await db.select(db.queueSessionItems).get(), isEmpty);
    });
  });
}

/// Records the largest number of variables any one statement binds.
class _VariableCountRecorder extends QueryInterceptor {
  int maxArgs = 0;

  void _note(List<Object?> args) {
    if (args.length > maxArgs) maxArgs = args.length;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    _note(args);
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runInsert(
      QueryExecutor executor, String statement, List<Object?> args) {
    _note(args);
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
      QueryExecutor executor, String statement, List<Object?> args) {
    _note(args);
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
      QueryExecutor executor, String statement, List<Object?> args) {
    _note(args);
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
      QueryExecutor executor, String statement, List<Object?> args) {
    _note(args);
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(
      QueryExecutor executor, BatchedStatements statements) {
    for (final args in statements.arguments) {
      _note(args.arguments);
    }
    return super.runBatched(executor, statements);
  }
}

Future<int> _playOrderCount(AppDatabase db, int sessionId) async {
  final row = await db
      .customSelect(
        'SELECT COUNT(*) AS c FROM queue_session_play_order WHERE session_id = ?',
        variables: [Variable.withInt(sessionId)],
      )
      .getSingle();
  return row.read<int>('c');
}

/// Every play-order row of a session: (play position, canonical position,
/// uuid), straight from the tables.
Future<List<(int, int, String)>> _orderRows(AppDatabase db, int sessionId) async {
  final rows = await db.customSelect(
    'SELECT po.play_position, qsi.position, qsi.uuid_id '
    'FROM queue_session_play_order AS po '
    'JOIN queue_session_items AS qsi ON qsi.item_id = po.item_id '
    'WHERE po.session_id = ? ORDER BY po.play_position',
    variables: [Variable.withInt(sessionId)],
  ).get();
  return [
    for (final r in rows)
      (r.read<int>('play_position'), r.read<int>('position'),
          r.read<String>('uuid_id')),
  ];
}
