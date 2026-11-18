// Phase 8B.2a / 8-C04 (unit half), spec §6 "fence late completion": a
// download that finishes after its track was deleted (sync tombstone) or
// after a Delete download fenced it routes its just-written file through
// `owned_file_cleanup`, so a failed delete is retried instead of orphaned.
// The downloader holds the path lock over rename → DB write, so a cleanup
// retry can never see a renamed-but-unrecorded file at a reused path; a path
// reused by a new download survives a stale row's retry.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';

import '../../helpers/server_binding.dart';
import '../../helpers/owned_file_cleanup_rows.dart';

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Title $uuid',
  artist: 'Artist',
  duration: 120,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

Future<List<Map<String, Object?>>> _cleanupRows(AppDatabase db) =>
    ownedFileCleanupRows(db, const ['id', 'path', 'attempts']);

Future<void> _waitForFinish(DownloadManager m) async {
  for (var i = 0; i < 2000; i++) {
    if (!m.snapshot().any((j) => j.isActive || j.isQueued)) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('download did not finish');
}

void main() {
  late AppDatabase db;
  late Directory docs;
  late Directory tracks;
  late LocalCoverArtStore coverStore;
  late Object? unlinkError;
  late int retryRequests;
  late OwnedFileCleanup cleanup;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    docs = await Directory.systemTemp.createTemp('owned_cleanup_late');
    tracks = Directory(p.join(docs.path, 'tracks'));
    unlinkError = null;
    retryRequests = 0;
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => docs,
      apiClient: testApiClient(
        'http://test:8080',
        MockClient((_) async => http.Response('', 404)),
      ),
    );
    cleanup = OwnedFileCleanup(
      db: db,
      documentsDirectory: () async => docs,
      locks: OwnedPathLocks(),
      deleteFile: (file) async {
        final error = unlinkError;
        if (error != null) throw error;
        await file.delete();
      },
    );
  });

  tearDown(() async {
    await db.close();
    if (docs.existsSync()) await docs.delete(recursive: true);
  });

  DownloadManager buildManager() {
    final manager = DownloadManager(
      apiClient: testApiClient(
        'http://test:8080',
        MockClient(
          (req) async => http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {'x-audio-extension': 'm4a'},
          ),
        ),
      ),
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => docs,
      ownedFileCleanup: cleanup,
      onOwnedCleanupPending: () => retryRequests++,
    );
    addTearDown(manager.dispose);
    return manager;
  }

  Future<void> insertTrack(String uuid) => db.into(db.tracks).insert(
    TracksCompanion.insert(uuidId: uuid, createdAt: 0, lastUpdated: 0),
  );

  Future<void> tombstone(String uuid) =>
      db.customStatement('DELETE FROM tracks WHERE uuid_id = ?', [uuid]);

  List<File> audioFiles() => tracks.existsSync()
      ? [
          for (final f in tracks.listSync().whereType<File>())
            if (!f.path.endsWith('.partial')) f,
        ]
      : const [];

  group('a late completion (track deleted before the DB write)', () {
    test('its file is cleaned and no row is left', () async {
      await insertTrack('u1');
      final manager = buildManager();
      manager.testHookBeforeDbWrite = (_) => tombstone('u1');
      await manager.enqueueTracks([_track('u1')], quality: '320');
      await _waitForFinish(manager);
      expect(audioFiles(), isEmpty);
      expect(await _cleanupRows(db), isEmpty);
    });

    test('a failed delete keeps a durable row and asks for a retry; the '
        'retry cleans it', () async {
      await insertTrack('u1');
      final manager = buildManager();
      manager.testHookBeforeDbWrite = (_) async {
        await tombstone('u1');
        unlinkError = const FileSystemException('Cannot delete file');
      };
      await manager.enqueueTracks([_track('u1')], quality: '320');
      await _waitForFinish(manager);
      final files = audioFiles();
      expect(files, hasLength(1));
      final kept = (await _cleanupRows(db)).single;
      expect((kept['path'], kept['attempts']), (files.single.path, 1));
      expect(retryRequests, greaterThan(0));

      unlinkError = null;
      await seedTestBinding(db); // a pass fences on a session's binding
    await cleanup.runPass({'retry'});
      expect(audioFiles(), isEmpty);
      expect(await _cleanupRows(db), isEmpty);
    });
  });

  test('a Delete download fencing the worker between rename and DB write '
      'cleans the renamed file through the cleanup', () async {
    await insertTrack('u1');
    final manager = buildManager();
    final hookEntered = Completer<void>();
    final releaseHook = Completer<void>();
    manager.testHookBeforeDbWrite = (_) async {
      if (!hookEntered.isCompleted) hookEntered.complete();
      await releaseHook.future;
    };
    await manager.enqueueTracks([_track('u1')], quality: '320');
    await hookEntered.future;
    unlinkError = const FileSystemException('Cannot delete file');
    final delete = manager.deleteDownload('u1');
    await Future<void>.delayed(Duration.zero);
    releaseHook.complete();
    await delete;
    await _waitForFinish(manager);
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('u1')))
        .getSingle();
    expect(row.filePath, isNull);
    final files = audioFiles();
    expect(files, hasLength(1), reason: 'the unlink failed');
    expect((await _cleanupRows(db)).map((r) => r['path']), [files.single.path]);

    unlinkError = null;
    await seedTestBinding(db); // a pass fences on a session's binding
    await cleanup.runPass({'retry'});
    expect(audioFiles(), isEmpty);
    expect(await _cleanupRows(db), isEmpty);
  });

  test('a path reused by a new download before the retry survives', () async {
    await insertTrack('u1');
    final first = buildManager();
    first.testHookBeforeDbWrite = (_) async {
      await tombstone('u1');
      unlinkError = const FileSystemException('Cannot delete file');
    };
    await first.enqueueTracks([_track('u1')], quality: '320');
    await _waitForFinish(first);
    final stale = (await _cleanupRows(db)).single;
    unlinkError = null;

    // The track comes back (sync upsert) and is downloaded again to the
    // same path before the stale row's retry.
    await insertTrack('u1');
    final second = buildManager();
    await second.enqueueTracks([_track('u1')], quality: '320');
    await _waitForFinish(second);
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('u1')))
        .getSingle();
    expect(row.filePath, stale['path']);

    await seedTestBinding(db); // a pass fences on a session's binding
    await cleanup.runPass({'retry'});
    expect(File(row.filePath!).existsSync(), isTrue);
    expect(await _cleanupRows(db), isEmpty, reason: 'stale row retired');
  });

  test('a cleanup retry waits for the downloader between rename and DB '
      'write, then keeps the newly recorded file', () async {
    await insertTrack('u1');
    final path = p.join(tracks.path, 'u1.m4a');
    // A stale row for the path, from an earlier copy whose delete failed.
    tracks.createSync(recursive: true);
    File(path).writeAsBytesSync([9, 9, 9, 9]);
    final staleIds = await db.transaction(
      () => cleanup.enqueueInTransaction([path], localBindingId: null),
    );
    File(path).deleteSync();

    final manager = buildManager();
    final hookEntered = Completer<void>();
    final releaseHook = Completer<void>();
    manager.testHookBeforeDbWrite = (_) async {
      if (!hookEntered.isCompleted) hookEntered.complete();
      await releaseHook.future;
    };
    await manager.enqueueTracks([_track('u1')], quality: '320');
    await hookEntered.future;
    expect(File(path).existsSync(), isTrue, reason: 'renamed into place');

    var retryDone = false;
    final retry = cleanup
        .cleanRows(staleIds, bindingToken: null)
        .whenComplete(() => retryDone = true);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(retryDone, isFalse, reason: 'the path lock is held by the commit');

    releaseHook.complete();
    expect(await retry, {staleIds.single: OwnedCleanupOutcome.retired});
    await _waitForFinish(manager);
    expect(File(path).existsSync(), isTrue);
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('u1')))
        .getSingle();
    expect(row.filePath, path);
  });
  // 8B.2b (DEV-8B2a-06 / OPEN-8B2a-01, spec §6 ¶6 "every local removal
  // path"): a re-download at another quality (a replacement) drops the
  // reference to the old file, and to a superseded damaged copy, in the
  // swap itself; both go through `owned_file_cleanup`, enqueued in the
  // swap's transaction and attempted only after it committed.
  group('a replacement swap', () {
    late String old;

    TrackUI downloaded(String uuid) => TrackUI(
      uuidId: uuid,
      createdAt: 0,
      lastUpdated: 0,
      title: 'Title $uuid',
      artist: 'Artist',
      duration: 120,
      bitrateKbps: 320,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
      filePath: old,
      downloadedBitrateKbps: 128,
      downloadedQuality: '128',
    );

    Future<void> insertDownloaded(String uuid, {String? damaged}) =>
        db.into(db.tracks).insert(TracksCompanion.insert(
              uuidId: uuid,
              createdAt: 0,
              lastUpdated: 0,
              filePath: Value(old),
              damagedFilePath: Value(damaged),
              downloadedBitrateKbps: const Value(128),
              downloadedQuality: const Value('128'),
            ));

    Future<Track> row(String uuid) =>
        (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .getSingle();

    setUp(() {
      tracks.createSync(recursive: true);
      old = p.join(tracks.path, 'u1.mp3');
      File(old).writeAsBytesSync([9, 9]);
    });

    test('a failed unlink of the old file keeps a durable row and asks for '
        'a retry; the retry deletes it', () async {
      await insertDownloaded('u1');
      unlinkError = const FileSystemException('Cannot delete file');
      final manager = buildManager();
      await manager.enqueueTracksAtQuality([downloaded('u1')], quality: '320');
      await _waitForFinish(manager);

      final now = await row('u1');
      expect(now.filePath, isNot(old));
      expect(File(now.filePath!).existsSync(), isTrue);
      expect(File(old).existsSync(), isTrue, reason: 'the unlink failed');
      expect([for (final r in await _cleanupRows(db)) (r['path'], r['attempts'])],
          [(old, 1)]);
      expect(retryRequests, greaterThan(0));

      unlinkError = null;
      await seedTestBinding(db); // a pass fences on a session's binding
      await cleanup.runPass({'retry'});
      expect(File(old).existsSync(), isFalse);
      expect(File(now.filePath!).existsSync(), isTrue);
      expect(await _cleanupRows(db), isEmpty);
    });

    test('the old file is deleted only once the row points at the new one',
        () async {
      await insertDownloaded('u1');
      final seenAtDelete = <String?>[];
      final probing = OwnedFileCleanup(
        db: db,
        documentsDirectory: () async => docs,
        locks: OwnedPathLocks(),
        deleteFile: (file) async {
          if (file.path == old) seenAtDelete.add((await row('u1')).filePath);
          await file.delete();
        },
      );
      cleanup = probing;
      final manager = buildManager();
      await manager.enqueueTracksAtQuality([downloaded('u1')], quality: '320');
      await _waitForFinish(manager);

      final now = (await row('u1')).filePath;
      expect(seenAtDelete, [now], reason: 'deleted once, after the swap');
      expect(now, isNot(old));
      expect(File(old).existsSync(), isFalse);
      expect(await _cleanupRows(db), isEmpty);
    });

    test('a superseded damaged copy goes through the cleanup too', () async {
      final damaged = p.join(tracks.path, 'u1.bad.mp3');
      File(damaged).writeAsBytesSync([7]);
      await insertDownloaded('u1', damaged: damaged);
      unlinkError = const FileSystemException('Cannot delete file');
      final manager = buildManager();
      await manager.enqueueTracksAtQuality([downloaded('u1')], quality: '320');
      await _waitForFinish(manager);

      final now = await row('u1');
      expect((now.filePath == old, now.damagedFilePath), (false, null));
      expect({for (final r in await _cleanupRows(db)) r['path']},
          {old, damaged});

      unlinkError = null;
      await seedTestBinding(db);
      await cleanup.runPass({'retry'});
      expect((File(old).existsSync(), File(damaged).existsSync()),
          (false, false));
      expect(await _cleanupRows(db), isEmpty);
    });

    test('a replacement that fails before the swap leaves the old download '
        'playable and enqueues nothing of it', () async {
      await insertDownloaded('u1');
      final manager = buildManager();
      manager.testHookBeforeDbWrite =
          (_) async => throw const FileSystemException('disk full');
      await manager.enqueueTracksAtQuality([downloaded('u1')], quality: '320');
      await _waitForFinish(manager);

      expect((await row('u1')).filePath, old);
      expect(File(old).readAsBytesSync(), [9, 9]);
      expect(
          [for (final r in await _cleanupRows(db)) r['path']], isNot(contains(old)));
    });
  });
}
