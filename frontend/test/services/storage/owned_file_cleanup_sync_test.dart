// Phase 8B.2a / 8-U08 / 8-C04 (unit half): a sync tombstone
// (`SyncService._deleteTracks`, fenced, serving `/changes` pages and
// `refetchAndApplyTrack`) enqueues the track's downloaded and damaged files
// into `owned_file_cleanup` in the same fenced transaction that deletes the
// row, then tries the delete after the commit. A failed delete keeps a
// durable row instead of being swallowed; a fenced (late) sync writes
// nothing and deletes nothing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../helpers/owned_file_cleanup_rows.dart';

Map<String, Object?> _delete(String uuid, int rev) =>
    {'type': 'delete', 'revision': rev, 'uuid_id': uuid, 'track': null};

Map<String, Object?> _page(List<Map<String, Object?>> changes, int latest) =>
    {'changes': changes, 'nextCursor': null, 'latestRevision': latest};

Future<List<Map<String, Object?>>> _cleanupRows(AppDatabase db) =>
    ownedFileCleanupRows(db, const ['path', 'local_binding_id', 'attempts']);

void main() {
  late AppDatabase db;
  late Directory docs;
  late Directory tracks;
  late String token;
  late Map<String, Object?> changes;
  late OwnedFileCleanup cleanup;
  late Object? unlinkError;
  Completer<void>? holdResponses;
  Completer<void>? requestArrived;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    docs = await Directory.systemTemp.createTemp('owned_cleanup_sync');
    tracks = Directory(p.join(docs.path, 'tracks'))..createSync();
    token = (await ServerBindingRepository(db)
            .ensureProvisional('http://test:8080'))
        .localBindingId;
    unlinkError = null;
    holdResponses = null;
    requestArrived = null;
    changes = _page([], 0);
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

  Future<SyncService> service() async {
    SharedPreferences.setMockInitialValues({});
    final api = testApiClient(
      'http://test:8080',
      MockClient((req) async {
        requestArrived?.complete();
        requestArrived = null;
        if (holdResponses != null) await holdResponses!.future;
        if (req.url.pathSegments.first == 'changes') {
          return http.Response(jsonEncode(changes), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('gone', 404);
      }),
    );
    return SyncService(
      db: db,
      api: TracksApi(api: api),
      queueRepository: QueueRepository(db),
      bindingToken: token,
      ownedFileCleanup: cleanup,
    );
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
          revision: const Value(1),
          filePath: Value(filePath),
          damagedFilePath: Value(damagedFilePath),
        ),
      );

  Future<List<String>> trackUuids() async =>
      [for (final t in await db.select(db.tracks).get()) t.uuidId];

  group('a /changes tombstone', () {
    test('deletes the downloaded and damaged files and leaves no row',
        () async {
      final f = download('u1.m4a');
      final d = download('u1.damaged.m4a');
      await insertTrack('u1', filePath: f.path, damagedFilePath: d.path);
      changes = _page([_delete('u1', 2)], 2);
      await (await service()).syncChanges();
      expect(await trackUuids(), isEmpty);
      expect((f.existsSync(), d.existsSync()), (false, false));
      expect(await _cleanupRows(db), isEmpty);
    });

    test('an unlink failure keeps a durable row with the sync token; a '
        'retry deletes the file', () async {
      final f = download('u1.m4a');
      await insertTrack('u1', filePath: f.path);
      changes = _page([_delete('u1', 2)], 2);
      unlinkError = const FileSystemException(
        'Cannot delete file',
        '',
        OSError('Operation not permitted', 1),
      );
      await (await service()).syncChanges();
      expect(await trackUuids(), isEmpty);
      expect(f.existsSync(), isTrue);
      expect(await _cleanupRows(db), [
        {'path': f.path, 'local_binding_id': token, 'attempts': 1},
      ]);

      unlinkError = null;
      await cleanup.runPass({'retry'});
      expect(f.existsSync(), isFalse);
      expect(await _cleanupRows(db), isEmpty);
    });

    test('the track row is never deleted without its cleanup row', () async {
      final f = download('u1.m4a');
      await insertTrack('u1', filePath: f.path);
      changes = _page([_delete('u1', 2)], 2);
      await db.customStatement('DROP TABLE owned_file_cleanup');
      await expectLater((await service()).syncChanges(), throwsA(anything));
      expect(await trackUuids(), ['u1']);
      expect(f.existsSync(), isTrue);
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 0);
    });

    test('a page arriving after a reset fence deletes nothing', () async {
      final f = download('u1.m4a');
      await insertTrack('u1', filePath: f.path);
      changes = _page([_delete('u1', 2)], 2);
      holdResponses = Completer<void>();
      final arrived = requestArrived = Completer<void>();
      final sync = (await service()).syncChanges();
      await arrived.future;
      await db.customStatement('DELETE FROM server_binding'); // reset fence
      holdResponses!.complete();
      await expectLater(sync, throwsA(isA<BindingFencedException>()));
      expect(await trackUuids(), ['u1']);
      expect(f.existsSync(), isTrue);
      expect(await _cleanupRows(db), isEmpty);
    });

    test('a recorded file outside the downloads root is never deleted',
        () async {
      final outside = File(p.join(docs.path, 'notes.m4a'))
        ..writeAsBytesSync([1, 2, 3]);
      await insertTrack('u1', filePath: outside.path);
      changes = _page([_delete('u1', 2)], 2);
      await (await service()).syncChanges();
      expect(await trackUuids(), isEmpty);
      expect(outside.existsSync(), isTrue);
      expect(await _cleanupRows(db), isEmpty);
    });

    // A.2 characterization: only the tombstoned track's files are read.
    test("another track's download and damaged copy are left alone",
        () async {
      final f = download('u1.m4a');
      final other = download('u2.m4a');
      final otherDamaged = download('u2.damaged.m4a');
      await insertTrack('u1', filePath: f.path);
      await insertTrack('u2',
          filePath: other.path, damagedFilePath: otherDamaged.path);
      changes = _page([_delete('u1', 2)], 2);
      await (await service()).syncChanges();
      expect(await trackUuids(), ['u2']);
      expect(f.existsSync(), isFalse);
      expect((other.existsSync(), otherDamaged.existsSync()), (true, true));
      expect(await _cleanupRows(db), isEmpty);
    });

    // A.2 characterization: the clean-up refuses a path a track still
    // names, so only what is enqueued shows that another track's files are
    // not read. An attempt that cannot resolve the root keeps the rows.
    test("only the tombstoned track's files are enqueued", () async {
      final f = download('u1.m4a');
      final d = download('u1.damaged.m4a');
      await insertTrack('u1', filePath: f.path, damagedFilePath: d.path);
      await insertTrack('u2',
          filePath: download('u2.m4a').path,
          damagedFilePath: download('u2.damaged.m4a').path);
      cleanup = OwnedFileCleanup(
        db: db,
        documentsDirectory: () async => throw const FileSystemException('no'),
        locks: OwnedPathLocks(),
      );
      changes = _page([_delete('u1', 2)], 2);
      await (await service()).syncChanges();
      expect(await trackUuids(), ['u2']);
      expect([for (final r in await _cleanupRows(db)) r['path']],
          [f.path, d.path]);
    });
  });

  // Review r1 #9: a damaged download keeps its path in both columns; it is
  // enqueued once.
  test('a path held in both columns is enqueued once', () async {
    final f = download('u1.m4a');
    await insertTrack('u1', filePath: f.path, damagedFilePath: f.path);
    changes = _page([_delete('u1', 2)], 2);
    unlinkError = const FileSystemException('Cannot delete file');
    await (await service()).syncChanges();
    expect(await _cleanupRows(db), hasLength(1));
  });

  group('refetchAndApplyTrack on a 404', () {
    test('deletes the file through the cleanup', () async {
      final f = download('u1.m4a');
      await insertTrack('u1', filePath: f.path);
      await (await service()).refetchAndApplyTrack('u1');
      expect(await trackUuids(), isEmpty);
      expect(f.existsSync(), isFalse);
      expect(await _cleanupRows(db), isEmpty);
    });

    test('an unlink failure keeps a durable row', () async {
      final f = download('u1.m4a');
      await insertTrack('u1', filePath: f.path);
      unlinkError = const FileSystemException('Cannot delete file');
      await (await service()).refetchAndApplyTrack('u1');
      expect(await trackUuids(), isEmpty);
      expect(f.existsSync(), isTrue);
      expect(await _cleanupRows(db), [
        {'path': f.path, 'local_binding_id': token, 'attempts': 1},
      ]);
    });
  });
}
