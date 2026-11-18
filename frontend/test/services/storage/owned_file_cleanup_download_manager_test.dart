// Phase 8B.2a / 8-U08 / 8-C04 (unit half): the user's Delete download
// (`DownloadManager.deleteDownload`) and Delete downloads for a scope
// (`deleteDownloadsForUuids`) enqueue their files into `owned_file_cleanup`
// in the same transaction that clears `tracks.file_path` /
// `damaged_file_path`, then try the delete at once. A failed delete is never
// swallowed: its row stays for the cleanup worker, and the manager asks for a
// retry. A file outside the app's downloads root is never deleted.
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdateQuery, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';

import '../../helpers/server_binding.dart';

Future<List<Map<String, Object?>>> _cleanupRows(AppDatabase db) async => [
  for (final r in await db
      .customSelect(
        'SELECT path, root_kind, size, local_binding_id, attempts '
        'FROM owned_file_cleanup ORDER BY id',
      )
      .get())
    r.data,
];

Future<(String?, String?)> _paths(AppDatabase db, String uuid) async {
  final row = await (db.select(db.tracks)
        ..where((t) => t.uuidId.equals(uuid)))
      .getSingle();
  return (row.filePath, row.damagedFilePath);
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
    docs = await Directory.systemTemp.createTemp('owned_cleanup_dm');
    tracks = Directory(p.join(docs.path, 'tracks'))..createSync();
    unlinkError = null;
    retryRequests = 0;
    final api = testApiClient(
      'http://test:8080',
      MockClient((_) async => http.Response('', 404)),
    );
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => docs,
      apiClient: api,
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
        MockClient((_) async => http.Response('', 404)),
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

  File download(String name) =>
      File(p.join(tracks.path, name))..writeAsBytesSync([1, 2, 3]);

  Future<void> insertTrack(
    String uuid, {
    String? filePath,
    String? damagedFilePath,
  }) =>
      db.into(db.tracks).insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          filePath: Value(filePath),
          damagedFilePath: Value(damagedFilePath),
          fileSizeBytes: const Value(3),
          downloadedQuality: const Value('320'),
        ),
      );

  for (final bulk in [false, true]) {
    final name = bulk ? 'deleteDownloadsForUuids' : 'deleteDownload';
    Future<void> delete(DownloadManager m, String uuid) =>
        bulk ? m.deleteDownloadsForUuids([uuid]) : m.deleteDownload(uuid);

    group(name, () {
      test('deletes the download and its damaged copy and leaves no row',
          () async {
        final f = download('u1.m4a');
        final d = download('u1.damaged.m4a');
        await insertTrack('u1', filePath: f.path, damagedFilePath: d.path);
        await delete(buildManager(), 'u1');
        expect((f.existsSync(), d.existsSync()), (false, false));
        expect(await _paths(db, 'u1'), (null, null));
        expect(await _cleanupRows(db), isEmpty);
        expect(retryRequests, 0);
      });

      test('an unlink failure keeps a durable row and asks for a retry; the '
          'retry deletes the file', () async {
        final f = download('u1.m4a');
        await insertTrack('u1', filePath: f.path);
        unlinkError = const FileSystemException(
          'Cannot delete file',
          '',
          OSError('Operation not permitted', 1),
        );
        await delete(buildManager(), 'u1');
        // The user's action still takes effect: the track streams again.
        expect(await _paths(db, 'u1'), (null, null));
        expect(f.existsSync(), isTrue);
        expect(await _cleanupRows(db), [
          {
            'path': f.path,
            'root_kind': 'downloads',
            'size': 3,
            'local_binding_id': null,
            'attempts': 1,
          },
        ]);
        expect(retryRequests, greaterThan(0));

        unlinkError = null;
        await seedTestBinding(db); // a pass fences on a session's binding
    await cleanup.runPass({'retry'});
        expect(f.existsSync(), isFalse);
        expect(await _cleanupRows(db), isEmpty);
      });

      test('rows carry the binding token of the session', () async {
        final token = await seedTestBinding(db);
        final f = download('u1.m4a');
        await insertTrack('u1', filePath: f.path);
        unlinkError = const FileSystemException('Cannot delete file');
        await delete(buildManager(), 'u1');
        expect(
          (await _cleanupRows(db)).single['local_binding_id'],
          token,
        );
      });

      test('the reference is never dropped without its cleanup row', () async {
        final f = download('u1.m4a');
        await insertTrack('u1', filePath: f.path);
        // The enqueue cannot be written: the clear must roll back with it.
        await db.customStatement('DROP TABLE owned_file_cleanup');
        await expectLater(delete(buildManager(), 'u1'), throwsA(anything));
        expect(await _paths(db, 'u1'), (f.path, null));
        expect(f.existsSync(), isTrue);
      });

      test('a recorded file outside the downloads root is never deleted',
          () async {
        final outside = File(p.join(docs.path, 'notes.m4a'))
          ..writeAsBytesSync([1, 2, 3]);
        await insertTrack('u1', filePath: outside.path);
        await delete(buildManager(), 'u1');
        expect(await _paths(db, 'u1'), (null, null));
        expect(outside.existsSync(), isTrue);
        expect(await _cleanupRows(db), isEmpty);
      });
    });
  }

  // Watchers of `tracks` (browse pages) learn of the cleared download only
  // once the immediate cleanup attempt is over: the operation does no DB
  // work after it publishes the change, so a watcher re-fetch can never sit
  // ahead of the attempt (a widget test's fake-async zone hung on that).
  for (final bulk in [false, true]) {
    test('${bulk ? 'deleteDownloadsForUuids' : 'deleteDownload'} publishes '
        'the tracks change after the cleanup attempt', () async {
      final f = download('u1.m4a');
      await insertTrack('u1', filePath: f.path);
      final manager = buildManager();
      final seenAtNotification = <(bool, int)>[];
      final sub = db
          .tableUpdates(TableUpdateQuery.onTable(db.tracks))
          .listen((_) async {
        seenAtNotification.add((
          f.existsSync(),
          (await _cleanupRows(db)).length,
        ));
      });
      addTearDown(sub.cancel);
      if (bulk) {
        await manager.deleteDownloadsForUuids(['u1']);
      } else {
        await manager.deleteDownload('u1');
      }
      for (var i = 0; i < 20 && seenAtNotification.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(seenAtNotification, isNotEmpty);
      expect(seenAtNotification.first, (false, 0),
          reason: 'file deleted and row cleared before the change is seen');
    });
  }

  // Review r1 #4: the reference-dropping transaction has committed, so an
  // attempt that fails unexpectedly must not fail the user's action.
  test('a cleanup attempt that throws still completes the delete and asks '
      'for a retry', () async {
    final f = download('u1.m4a');
    await insertTrack('u1', filePath: f.path);
    final manager = DownloadManager(
      apiClient: testApiClient(
        'http://test:8080',
        MockClient((_) async => http.Response('', 404)),
      ),
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => docs,
      ownedFileCleanup: OwnedFileCleanup(
        db: db,
        documentsDirectory: () async => throw const FileSystemException('no'),
        locks: OwnedPathLocks(),
      ),
      onOwnedCleanupPending: () => retryRequests++,
    );
    addTearDown(manager.dispose);
    await manager.deleteDownload('u1');
    expect(await _paths(db, 'u1'), (null, null));
    expect(await _cleanupRows(db), hasLength(1));
    expect(retryRequests, 1);
  });

  test('deleteDownloadsForUuids enqueues every chunk', () async {
    final uuids = [for (var i = 0; i < 205; i++) 'u$i'];
    for (final u in uuids) {
      await insertTrack(u, filePath: download('$u.m4a').path);
    }
    unlinkError = const FileSystemException('Cannot delete file');
    await buildManager().deleteDownloadsForUuids(uuids);
    expect(await _cleanupRows(db), hasLength(205));
    unlinkError = null;
    await seedTestBinding(db); // a pass fences on a session's binding
    await cleanup.runPass({'retry'});
    expect(tracks.listSync(), isEmpty);
    expect(await _cleanupRows(db), isEmpty);
  });
}
