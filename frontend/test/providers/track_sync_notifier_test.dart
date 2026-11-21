import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Listenable;
import 'package:drift/drift.dart' show QueryRow, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_offline.dart';

class _SwapClient extends BaseClient {
  Client inner = MockClient((_) async => throw StateError('no client installed'));
  @override
  Future<StreamedResponse> send(BaseRequest request) => inner.send(request);
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

Future<List<int>> _playPositions(AppDatabase db, int sessionId) async {
  final rows = await db
      .customSelect(
        'SELECT play_position '
        'FROM queue_session_play_order '
        'WHERE session_id = ? '
        'ORDER BY play_position',
        variables: [Variable.withInt(sessionId)],
      )
      .get();
  return rows.map((row) => row.read<int>('play_position')).toList();
}

Future<List<int>> _canonicalPositions(AppDatabase db, int sessionId) async {
  final rows = await db
      .customSelect(
        'SELECT position '
        'FROM queue_session_items '
        'WHERE session_id = ? AND queue_type = ? '
        'ORDER BY position',
        variables: [
          Variable.withInt(sessionId),
          Variable.withString(QueueItemTypes.main),
        ],
      )
      .get();
  return rows.map((row) => row.read<int>('position')).toList();
}

/// Completes once [condition] holds, re-checked on every change [listenable]
/// reports (no polling); fails after [limit] of real time, the bound for work
/// that runs through real file I/O.
Future<void> _whenChanged(Listenable listenable, bool Function() condition,
    {Duration limit = const Duration(seconds: 5)}) async {
  if (condition()) return;
  final met = Completer<void>();
  void check() {
    if (!met.isCompleted && condition()) met.complete();
  }

  listenable.addListener(check);
  try {
    await met.future.timeout(limit,
        onTimeout: () =>
            throw StateError('condition was not met within $limit'));
  } finally {
    listenable.removeListener(check);
  }
}

Map<String, dynamic> _minimalMetadataJson() => {
  'duration': 0.0,
  'bitrate_kbps': 0.0,
  'sample_rate_hz': 0,
  'channels': 0,
  'has_album_art': false,
};

Map<String, dynamic> _richMetadataJson({
  required String title,
  required String artist,
  required String album,
  required int artistId,
  required int albumId,
  bool hasAlbumArt = false,
  int? coverArtId,
}) => {
  'title': title,
  'artist': artist,
  'album': album,
  'album_artist': artist,
  'artist_id': artistId,
  'album_id': albumId,
  'duration': 180.0,
  'bitrate_kbps': 320.0,
  'sample_rate_hz': 44100,
  'channels': 2,
  'has_album_art': hasAlbumArt,
  'cover_art_id': coverArtId,
};

Map<String, dynamic> _trackJson(String uuid, {int revision = 1}) => {
  'uuid_id': uuid,
  'created_at': 1000,
  'last_updated': 2000,
  'revision': revision,
  'metadata': _minimalMetadataJson(),
};

Map<String, dynamic> _richTrackJson(
  String uuid, {
  required String title,
  required String artist,
  required String album,
  required int artistId,
  required int albumId,
  int createdAt = 1000,
  bool hasAlbumArt = false,
  int? coverArtId,
}) => {
  'uuid_id': uuid,
  'created_at': createdAt,
  'last_updated': createdAt,
  'revision': createdAt,
  'metadata': _richMetadataJson(
    title: title,
    artist: artist,
    album: album,
    artistId: artistId,
    albumId: albumId,
    hasAlbumArt: hasAlbumArt,
    coverArtId: coverArtId,
  ),
};

Map<String, dynamic> _upsert(int revision, Map<String, dynamic> trackJson) => {
  'type': 'upsert',
  'revision': revision,
  'uuid_id': trackJson['uuid_id'],
  'track': trackJson,
};

Map<String, dynamic> _delete(int revision, String uuid) => {
  'type': 'delete',
  'revision': revision,
  'uuid_id': uuid,
  'track': null,
};

Response _changesResponse(
  List<Map<String, dynamic>> changes, {
  int? nextCursor,
  int? latestRevision,
}) => Response(
  jsonEncode({
    'changes': changes,
    'nextCursor': nextCursor,
    'latestRevision':
        latestRevision ?? (changes.isEmpty ? 0 : changes.last['revision']),
  }),
  200,
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late Directory tempDir;
  late ApiClient api;
  late _SwapClient swap;

  // Tests reinstall their mock mid-test (after the container exists), so one
  // client delegates to a mutable inner mock.
  void installClient(String url, Client mock) {
    expect(url, 'http://localhost:8000');
    swap.inner = mock;
  }

  setUp(() async {
    swap = _SwapClient();
    api = testApiClient('http://localhost:8000', swap);
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db);
    tempDir = Directory.systemTemp.createTempSync('track_sync_notifier_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  ProviderContainer createContainer({
    bool offline = false,
    LocalCoverArtStore? localCoverArtStore,
    Directory? downloadDirectory,
    TestOffline? toggleOffline,
  }) {
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        databaseProvider.overrideWithValue(db),
        autoVerifiedGateOverride(),
        tracksApiProvider.overrideWithValue(TracksApi(api: api)),
        offlineModeProvider.overrideWith(
            () => toggleOffline ?? TestOffline(offline)),
        if (localCoverArtStore != null)
          localCoverArtStoreProvider.overrideWithValue(localCoverArtStore),
        if (downloadDirectory != null)
          downloadDirectoryProvider.overrideWithValue(
            () async => downloadDirectory,
          ),
      ],
    );
    return container;
  }

  Future<void> waitForBuild(ProviderContainer c) async {
    await c.read(trackSyncProvider.future);
    // A session's connection is verified before user-driven syncFresh runs
    // (it fails fast otherwise; audit 5A.0(a) #2).
    await c.read(serverBindingGateProvider).awaitVerified();
  }

  group('TrackSyncNotifier', () {
    // Phase M §7.7 (M-U24): a 401 is a wait, not a failure. The session is
    // already signed out (the gate closed); sync and refreshTrack publish no
    // error, keep the cursor and the track, and the next run waits at the
    // gate.
    group('a 401 waits', () {
      Response unauthorized() => Response(
        '{"detail":{"code":"invalid_token","message":"Sign in again."}}',
        401,
        headers: {'content-type': 'application/json'},
      );

      test('sync: no error, cursor unchanged, not syncing', () async {
        installClient('http://localhost:8000',
            MockClient((req) async => unauthorized()));
        final c = createContainer();
        await waitForBuild(c);
        await c.read(trackSyncProvider.notifier).sync();
        final state = c.read(trackSyncProvider).value!;
        expect(state.error, isNull);
        expect(state.libraryError, isNull);
        expect(state.isSyncing, isFalse);
        expect(state.librarySyncing, isFalse);
        expect(await SyncCursorStore(db).read(SyncStream.catalog), 0);
      });

      test('sync: an earlier library error is kept, not replaced', () async {
        installClient('http://localhost:8000',
            MockClient((req) async => Response('server error', 500)));
        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();
        final before = c.read(trackSyncProvider).value!.libraryError;
        expect(before, isNotNull);
        installClient('http://localhost:8000',
            MockClient((req) async => unauthorized()));
        await notifier.sync();
        expect(c.read(trackSyncProvider).value!.libraryError, before);
      });

      test('refreshTrack: the track stays and no error is published',
          () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([_upsert(1, _trackJson('uuid-1'))]),
          ),
        );
        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();
        installClient('http://localhost:8000',
            MockClient((req) async => unauthorized()));
        final refreshed = await notifier.refreshTrack('uuid-1');
        expect(refreshed, isFalse);
        expect(c.read(trackSyncProvider).value!.error, isNull);
        expect(
          (await db.select(db.tracks).get()).map((t) => t.uuidId),
          ['uuid-1'],
        );
      });
    });

    test(
      'first sync requests after_revision=0, upserts, saves the catalog '
      'cursor',
      () async {
        final requestUrls = <Uri>[];
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            requestUrls.add(req.url);
            return _changesResponse([
              _upsert(1, _trackJson('uuid-1')),
              _upsert(2, _trackJson('uuid-2')),
            ]);
          }),
        );

        final c = createContainer();
        await waitForBuild(c);
        await c.read(trackSyncProvider.notifier).sync();

        expect(requestUrls.length, 1);
        final params = requestUrls[0].queryParameters;
        expect(params['after_revision'], '0');
        expect(params['limit'], '500');

        final tracks = await db.select(db.tracks).get();
        expect(tracks.map((t) => t.uuidId).toSet(), {'uuid-1', 'uuid-2'});
        expect((await db.select(db.trackmetadata).get()).length, 2);

        expect(await SyncCursorStore(db).read(SyncStream.catalog), 2);
      },
    );

    test('upsert stores the per-track revision from the payload, and a later '
        'upsert overwrites it', () async {
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          // The envelope revision (sync watermark) is deliberately set
          // different from the track-payload revision so this proves the
          // stored value comes from the payload, not the envelope.
          if (call == 1) {
            return _changesResponse([
              _upsert(1, _trackJson('uuid-1', revision: 7)),
            ]);
          }
          return _changesResponse([
            _upsert(2, _trackJson('uuid-1', revision: 9)),
          ]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);

      await c.read(trackSyncProvider.notifier).sync();
      final afterFirst = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('uuid-1'))).getSingle();
      expect(afterFirst.revision, 7);

      await c.read(trackSyncProvider.notifier).sync();
      final afterSecond = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('uuid-1'))).getSingle();
      expect(afterSecond.revision, 9);
    });

    test(
      'subsequent sync sends the stored revision as after_revision',
      () async {
        await SyncCursorStore(db).write(SyncStream.catalog, 5);
        // Seed a local row that must survive (proves no resetLocalData).
        await db
            .into(db.tracks)
            .insert(
              TracksCompanion.insert(
                uuidId: 'pre-existing',
                createdAt: 0,
                lastUpdated: 0,
              ),
            );

        Uri? captured;
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            captured = req.url;
            return _changesResponse([]);
          }),
        );

        final c = createContainer();
        await waitForBuild(c);
        await c.read(trackSyncProvider.notifier).sync();

        expect(captured!.queryParameters['after_revision'], '5');
        final survivors = await db.select(db.tracks).get();
        expect(survivors.map((t) => t.uuidId), contains('pre-existing'));
      },
    );

    test(
      'multi-page sync follows nextCursor, advancing after_revision',
      () async {
        final afterParams = <String?>[];
        var call = 0;
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            afterParams.add(req.url.queryParameters['after_revision']);
            call++;
            if (call == 1) {
              return _changesResponse([
                _upsert(1, _trackJson('uuid-1')),
              ], nextCursor: 1);
            } else if (call == 2) {
              return _changesResponse([
                _upsert(2, _trackJson('uuid-2')),
              ], nextCursor: 2);
            }
            return _changesResponse([_upsert(3, _trackJson('uuid-3'))]);
          }),
        );

        final c = createContainer();
        await waitForBuild(c);
        await c.read(trackSyncProvider.notifier).sync();

        expect(call, 3);
        // Each page resumes from the previous page's last revision.
        expect(afterParams, ['0', '1', '2']);
        expect((await db.select(db.tracks).get()).length, 3);

        expect(await SyncCursorStore(db).read(SyncStream.catalog), 3);
      },
    );

    test(
      're-upserting the same uuid updates rather than duplicating',
      () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([_upsert(1, _trackJson('uuid-1'))]),
          ),
        );

        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();
        expect((await db.select(db.tracks).get()).length, 1);

        // Server re-emits the same uuid at a higher revision.
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([_upsert(2, _trackJson('uuid-1'))]),
          ),
        );
        await notifier.sync();
        expect((await db.select(db.tracks).get()).length, 1);
      },
    );

    test('FTS tables are populated after a multi-page sync', () async {
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          if (call == 1) {
            return _changesResponse([
              _upsert(1, _trackJson('uuid-1')),
            ], nextCursor: 1);
          }
          return _changesResponse([_upsert(2, _trackJson('uuid-2'))]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      final ftsRows = await db
          .customSelect('SELECT rowid FROM fts_tracks')
          .get();
      expect(ftsRows.length, 2);
    });

    test('concurrent sync call is a no-op', () async {
      var callCount = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          callCount++;
          return _changesResponse([_upsert(1, _trackJson('uuid-1'))]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);

      // Both calls are made before either has awaited anything.
      final f1 = notifier.sync();
      final f2 = notifier.sync();
      await Future.wait([f1, f2]);

      expect(callCount, 1);
    });

    // A.12 characterization: a sync flushes the edit outbox and pulls
    // `/changes` in one locked section, so an edit saved while the flush is
    // in flight is stored only after the pull (the pull's full-row upsert
    // cannot land on top of it).
    test('an edit saved while a sync is flushing is stored after its pull',
        () async {
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(1, _trackJson('uuid-1')),
            _upsert(2, _trackJson('uuid-2')),
          ]),
        ),
      );
      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();
      final outbox = c.read(editOutboxProvider);
      await outbox.enqueue(
        uuidId: 'uuid-1',
        edit: const MetadataEdit.empty().set('title', 'First'),
        writeMode: EditWriteMode.dbOnly,
        baseRevision: 1,
      );

      final events = <String>[];
      final patchArrived = Completer<void>();
      final releasePatch = Completer<void>();
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PATCH') {
            events.add('flush');
            if (!patchArrived.isCompleted) patchArrived.complete();
            await releasePatch.future;
            return Response(
              jsonEncode(
                  {'uuid_id': 'uuid-1', 'revision': 3, 'master_written': false}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          events.add('pull');
          return _changesResponse([
            _upsert(3, _trackJson('uuid-1', revision: 3)),
          ]);
        }),
      );
      final sync = notifier.sync();
      await patchArrived.future;
      final saved = outbox
          .enqueue(
            uuidId: 'uuid-2',
            edit: const MetadataEdit.empty().set('title', 'Second'),
            writeMode: EditWriteMode.dbOnly,
            baseRevision: 2,
          )
          .then((_) => events.add('saved'));
      await pumpEventQueue();
      releasePatch.complete();
      await sync;
      await saved;

      expect(events, ['flush', 'pull', 'saved']);
      final pending = await db.select(db.pendingEdits).get();
      expect(pending.map((r) => r.uuidId), ['uuid-2']);
    });

    // A.12 characterization: a run bumps each counter once, and only for its
    // own kind of change.
    test('a sync that only adds tracks bumps no counter; one that removes a '
        'queued track bumps each once; one that removes an unqueued track '
        'bumps only the download counter; an empty pull bumps none', () async {
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(1, _trackJson('uuid-a')),
            _upsert(2, _trackJson('uuid-b')),
            _upsert(3, _trackJson('uuid-c')),
          ]),
        ),
      );
      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();
      var state = c.read(trackSyncProvider).value!;
      expect(state.queueMutationVersion, 0);
      expect(state.downloadMutationVersion, 0);

      final id = await QueueRepository(db).createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['uuid-a', 'uuid-b'],
        currentIndex: 0,
      );
      installClient(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse([_delete(4, 'uuid-b')])),
      );
      await notifier.sync();
      state = c.read(trackSyncProvider).value!;
      expect(state.queueMutationVersion, 1);
      expect(state.downloadMutationVersion, 1);
      expect(state.affectedQueueSessionIds, {id});
      expect(state.deletedTrackUuids, {'uuid-b'});

      installClient(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse([_delete(5, 'uuid-c')])),
      );
      await notifier.sync();
      state = c.read(trackSyncProvider).value!;
      expect(state.queueMutationVersion, 1);
      expect(state.downloadMutationVersion, 2);
      expect(state.affectedQueueSessionIds, isEmpty);
      expect(state.deletedTrackUuids, {'uuid-c'});

      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse(const [], latestRevision: 5),
        ),
      );
      await notifier.sync();
      state = c.read(trackSyncProvider).value!;
      expect(state.error, isNull);
      expect(state.queueMutationVersion, 1);
      expect(state.downloadMutationVersion, 2);
    });

    test(
      'refreshTrack cannot publish the same mutation version as a concurrent sync',
      () async {
        // Both operations locally delete a track, so each publishes a
        // mutation-version bump. The queue player drops any state whose
        // version is <= the last one it saw, so two concurrent operations
        // publishing the SAME version silently lose one reconciliation.
        // refreshTrack must serialize with sync via the isSyncing guard.
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([
              _upsert(1, _trackJson('uuid-a')),
              _upsert(2, _trackJson('uuid-b')),
            ]),
          ),
        );
        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();

        // Every published version bump must be unique and increasing.
        final publishedVersions = <int>[];
        c.listen<AsyncValue<TrackSyncState>>(trackSyncProvider, (_, next) {
          final v = next.value;
          if (v != null && v.deletedTrackUuids.isNotEmpty) {
            publishedVersions.add(v.downloadMutationVersion);
          }
        });

        // /changes carrying a delete, held until the refresh has been
        // tried; single-track GET reports gone.
        final changesEntered = Completer<void>();
        final releaseChanges = Completer<void>();
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            if (req.url.path.endsWith('/changes')) {
              if (!changesEntered.isCompleted) changesEntered.complete();
              await releaseChanges.future;
              return _changesResponse([_delete(3, 'uuid-a')]);
            }
            return Response('', 404);
          }),
        );

        final syncFuture = notifier.sync();
        await changesEntered.future; // the sync is in flight
        final refreshedDuringSync = await notifier.refreshTrack('uuid-b');
        releaseChanges.complete();
        await syncFuture;

        // Serialized: the refresh is skipped while the sync is in flight
        // (its take_server marker is retried after the sync).
        expect(refreshedDuringSync, isFalse);
        expect(c.read(trackSyncProvider).value!.downloadMutationVersion, 1);

        final refreshedAfterSync = await notifier.refreshTrack('uuid-b');
        expect(refreshedAfterSync, isTrue);
        expect(c.read(trackSyncProvider).value!.downloadMutationVersion, 2);
        expect(await db.getTrackByUuid('uuid-b'), isEmpty);

        // No version was ever published twice.
        expect(publishedVersions.toSet().length, publishedVersions.length);
        expect(publishedVersions, [1, 2]);
      },
    );

    // Re-audit 4A #4: the library status is the library sync's own.
    test(
      'libraryError: set by a failed library sync, untouched by a '
      'single-track refresh, cleared by the next good library sync',
      () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([_upsert(1, _trackJson('uuid-1'))]),
          ),
        );
        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();
        expect(c.read(trackSyncProvider).value!.libraryError, isNull);

        installClient(
          'http://localhost:8000',
          MockClient((req) async => Response('server error', 500)),
        );
        final seenLibrarySyncing = <bool>[];
        c.listen<AsyncValue<TrackSyncState>>(trackSyncProvider, (_, next) {
          seenLibrarySyncing.add(next.value?.librarySyncing ?? false);
        });
        await notifier.sync();
        expect(seenLibrarySyncing, contains(true));
        expect(c.read(trackSyncProvider).value!.libraryError, isNotNull);

        seenLibrarySyncing.clear();
        await notifier.refreshTrack('uuid-1'); // fails (500)
        expect(seenLibrarySyncing, isNot(contains(true)));
        expect(
          c.read(trackSyncProvider).value!.libraryError,
          isNotNull,
          reason: 'a refresh failure is not a library failure',
        );

        installClient(
          'http://localhost:8000',
          MockClient(
            // Caught up at revision 1 (a lower latestRevision would be a
            // restored server, SC-01 rule 5).
            (req) async => req.url.path.endsWith('/changes')
                ? _changesResponse(const [], latestRevision: 1)
                : Response(jsonEncode(_trackJson('uuid-1')), 200),
          ),
        );
        await notifier.refreshTrack('uuid-1'); // succeeds
        expect(
          c.read(trackSyncProvider).value!.libraryError,
          isNotNull,
          reason: 'a good refresh does not hide a failed library sync',
        );
        await notifier.sync();
        expect(c.read(trackSyncProvider).value!.libraryError, isNull);
      },
    );

    // Other-issues decision 3 (a): a server whose library looks restored from
    // an older backup is its own library failure (a Retry cannot help); any
    // other failure, and a good sync, clear it.
    test(
      'libraryServerRestored: set by a library sync that finds the server '
      'behind this device, cleared by another failure and by a good sync',
      () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([_upsert(5, _trackJson('uuid-1'))]),
          ),
        );
        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();
        expect(c.read(trackSyncProvider).value!.libraryServerRestored, isFalse);

        // The server now reports a latest revision below this device's 5.
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse(const [], latestRevision: 2),
          ),
        );
        await notifier.sync();
        var state = c.read(trackSyncProvider).value!;
        expect(state.libraryError, isNotNull);
        expect(state.libraryServerRestored, isTrue);

        installClient(
          'http://localhost:8000',
          MockClient((req) async => Response('server error', 500)),
        );
        await notifier.sync();
        state = c.read(trackSyncProvider).value!;
        expect(state.libraryError, isNotNull);
        expect(state.libraryServerRestored, isFalse,
            reason: 'another failure is an ordinary one, with Retry');

        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse(const [], latestRevision: 2),
          ),
        );
        await notifier.sync();
        expect(c.read(trackSyncProvider).value!.libraryServerRestored, isTrue);
        // A single-track refresh leaves the library's failure as it is.
        installClient(
          'http://localhost:8000',
          MockClient((req) async => Response('server error', 500)),
        );
        await notifier.refreshTrack('uuid-1');
        expect(c.read(trackSyncProvider).value!.libraryServerRestored, isTrue);

        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse(const [], latestRevision: 5),
          ),
        );
        await notifier.sync();
        state = c.read(trackSyncProvider).value!;
        expect(state.libraryError, isNull);
        expect(state.libraryServerRestored, isFalse);
      },
    );

    test('offline sync skip makes no API request', () async {
      var callCount = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          callCount++;
          return _changesResponse([_upsert(1, _trackJson('uuid-offline'))]);
        }),
      );

      final c = createContainer(offline: true);
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      expect(callCount, 0);
      expect(await db.select(db.tracks).get(), isEmpty);
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 0);
    });

    test(
      'failed later page resumes from the last applied page cursor',
      () async {
        final afterParams = <String?>[];
        var call = 0;
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            afterParams.add(req.url.queryParameters['after_revision']);
            call++;
            if (call == 1) {
              return _changesResponse([
                _upsert(1, _trackJson('uuid-1')),
              ], nextCursor: 1);
            }
            return Response('server error', 500);
          }),
        );

        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();

        expect(afterParams, ['0', '1']);
        expect((await db.select(db.tracks).get()).map((t) => t.uuidId), [
          'uuid-1',
        ]);
        expect(await SyncCursorStore(db).read(SyncStream.catalog), 1);
        expect(c.read(trackSyncProvider).value!.error, isNotNull);

        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            expect(req.url.queryParameters['after_revision'], '1');
            return _changesResponse([_upsert(2, _trackJson('uuid-2'))]);
          }),
        );
        await notifier.sync();

        expect(
          (await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(),
          {'uuid-1', 'uuid-2'},
        );
        expect(await SyncCursorStore(db).read(SyncStream.catalog), 2);
        expect(c.read(trackSyncProvider).value!.error, isNull);
      },
    );

    test(
      'malformed change payload leaves existing watermark unchanged',
      () async {
        await SyncCursorStore(db).write(SyncStream.catalog, 5);
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            expect(req.url.queryParameters['after_revision'], '5');
            return Response(
              jsonEncode({
                'changes': [
                  {
                    'type': 'upsert',
                    'revision': 6,
                    'uuid_id': 'uuid-bad',
                    'track': null,
                  },
                ],
                'nextCursor': null,
                'latestRevision': 6,
              }),
              200,
            );
          }),
        );

        final c = createContainer();
        await waitForBuild(c);
        await c.read(trackSyncProvider.notifier).sync();

        expect(await db.select(db.tracks).get(), isEmpty);
        expect(await SyncCursorStore(db).read(SyncStream.catalog), 5);
        expect(
          c.read(trackSyncProvider).value!.error,
          contains('FormatException'),
        );
      },
    );

    test('non-advancing nextCursor fails without changing watermark', () async {
      installClient(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse(const [], nextCursor: 0)),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      expect(await SyncCursorStore(db).read(SyncStream.catalog), 0);
      expect(
        c.read(trackSyncProvider).value!.error,
        contains('Invalid non-advancing changes cursor'),
      );
    });

    test(
      'mismatched change and track uuid leaves existing watermark unchanged',
      () async {
        await SyncCursorStore(db).write(SyncStream.catalog, 5);
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            expect(req.url.queryParameters['after_revision'], '5');
            return Response(
              jsonEncode({
                'changes': [
                  {
                    'type': 'upsert',
                    'revision': 6,
                    'uuid_id': 'uuid-change',
                    'track': _trackJson('uuid-track'),
                  },
                ],
                'nextCursor': null,
                'latestRevision': 6,
              }),
              200,
            );
          }),
        );

        final c = createContainer();
        await waitForBuild(c);
        await c.read(trackSyncProvider.notifier).sync();

        expect(await db.select(db.tracks).get(), isEmpty);
        expect(await SyncCursorStore(db).read(SyncStream.catalog), 5);
        expect(
          c.read(trackSyncProvider).value!.error,
          contains('Change uuid_id must match track uuid_id'),
        );
      },
    );

    test('a second sync adds newly-changed tracks to FTS', () async {
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(
              1,
              _richTrackJson(
                'uuid-first',
                title: 'Alpha Song',
                artist: 'Alpha Artist',
                album: 'Alpha Album',
                artistId: 1,
                albumId: 1,
              ),
            ),
          ]),
        ),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      var ftsRows = await db
          .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Alpha\"*'",
          )
          .get();
      expect(ftsRows.length, 1);

      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(
              2,
              _richTrackJson(
                'uuid-second',
                title: 'Bravo Song',
                artist: 'Bravo Artist',
                album: 'Bravo Album',
                artistId: 2,
                albumId: 2,
              ),
            ),
          ]),
        ),
      );
      await notifier.sync();

      expect((await db.select(db.trackmetadata).get()).length, 2);
      ftsRows = await db
          .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Bravo\"*'",
          )
          .get();
      expect(ftsRows.length, 1);
    });

    test('a delete entry removes the track from the DB and FTS', () async {
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(
              1,
              _richTrackJson(
                'uuid-keep',
                title: 'Keep Song',
                artist: 'Keep Artist',
                album: 'Keep Album',
                artistId: 10,
                albumId: 100,
              ),
            ),
            _upsert(
              2,
              _richTrackJson(
                'uuid-drop',
                title: 'Drop Song',
                artist: 'Drop Artist',
                album: 'Drop Album',
                artistId: 11,
                albumId: 101,
              ),
            ),
          ]),
        ),
      );

      final c = createContainer(downloadDirectory: tempDir);
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-keep',
        'uuid-drop',
      });
      // Under the downloads root: only files there are the app's to delete.
      final downloadedFile = File('${tempDir.path}/tracks/uuid-drop.audio')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      // Review (decision 6): a kept damaged copy goes with the track too.
      // (A row holds one or the other; both columns are collected.)
      final damagedFile = File('${tempDir.path}/tracks/uuid-drop.damaged.audio')
        ..writeAsBytesSync([9]);
      await (db.update(
        db.tracks,
      )..where((t) => t.uuidId.equals('uuid-drop'))).write(
        TracksCompanion(
          damagedFilePath: Value(damagedFile.path),
          filePath: Value(downloadedFile.path),
          downloadedBitrateKbps: const Value(320),
          fileSizeBytes: const Value(3),
          downloadedQuality: const Value('320'),
        ),
      );

      // Next sync streams the deletion.
      installClient(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse([_delete(3, 'uuid-drop')])),
      );
      await notifier.sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-keep',
      });
      expect(downloadedFile.existsSync(), isFalse);
      expect(damagedFile.existsSync(), isFalse);
      final dropFts = await db
          .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Drop\"*'",
          )
          .get();
      expect(dropFts.length, 0);
      final keepFts = await db
          .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Keep\"*'",
          )
          .get();
      expect(keepFts.length, 1);
      expect(
        await (db.select(db.albums)..where((a) => a.id.equals(101))).get(),
        isEmpty,
      );
      expect(
        await (db.select(db.artists)..where((a) => a.id.equals(11))).get(),
        isEmpty,
      );
      final dropArtistFts = await db
          .customSelect(
            "SELECT rowid FROM fts_artists WHERE fts_artists MATCH '\"Drop\"*'",
          )
          .get();
      expect(dropArtistFts, isEmpty);
      final dropAlbumFts = await db
          .customSelect(
            "SELECT rowid FROM fts_albums WHERE fts_albums MATCH '\"Drop\"*'",
          )
          .get();
      expect(dropAlbumFts, isEmpty);
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 3);
    });

    // 8-fix-r1 8-R1-12 (spec §7 "offline second client", unit half): a
    // client that is offline while another deletes a track keeps its row,
    // queue entry and download; the tombstone sync after it reconnects
    // removes all three.
    test('an offline client keeps its download until the tombstone sync, '
        'then removes row, queue entry and file', () async {
      installClient(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse([
              _upsert(1, _trackJson('uuid-keep')),
              _upsert(2, _trackJson('uuid-drop')),
            ])),
      );
      final offline = TestOffline(false);
      final c = createContainer(
          downloadDirectory: tempDir, toggleOffline: offline);
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();
      final file = File('${tempDir.path}/tracks/uuid-drop.audio')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('uuid-drop')))
          .write(TracksCompanion(
        filePath: Value(file.path),
        downloadedBitrateKbps: const Value(320),
        fileSizeBytes: const Value(3),
        downloadedQuality: const Value('320'),
      ));
      final queueRepo = QueueRepository(db);
      final sessionId = await queueRepo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['uuid-keep', 'uuid-drop']);

      // Another client deletes uuid-drop; this one is offline.
      var requests = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          requests++;
          return _changesResponse([_delete(3, 'uuid-drop')]);
        }),
      );
      offline.set(true);
      await notifier.sync();

      expect(requests, 0);
      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(),
          {'uuid-keep', 'uuid-drop'});
      expect(file.existsSync(), isTrue, reason: 'still playable offline');
      expect(
          (await queueRepo.getSessionTracksInPlayOrder(sessionId))
              .map((e) => e.uuidId),
          ['uuid-keep', 'uuid-drop']);

      offline.set(false);
      await notifier.sync();

      expect(requests, 1);
      expect((await db.select(db.tracks).get()).map((t) => t.uuidId),
          ['uuid-keep']);
      expect(file.existsSync(), isFalse);
      expect(
          (await queueRepo.getSessionTracksInPlayOrder(sessionId))
              .map((e) => e.uuidId),
          ['uuid-keep']);
      expect(c.read(trackSyncProvider).value!.deletedTrackUuids, {'uuid-drop'});
    });

    test('sync tombstones fence active download jobs', () async {
      var deleteMode = false;
      final downloadStream = StreamController<List<int>>();
      final streamStarted = Completer<void>();
      installClient(
        'http://localhost:8000',
        MockClient.streaming((req, _) async {
          if (req.url.path.endsWith('/changes')) {
            final body = deleteMode
                ? _changesResponse([_delete(2, 'uuid-drop')]).body
                : _changesResponse([
                    _upsert(
                      1,
                      _richTrackJson(
                        'uuid-drop',
                        title: 'Drop Song',
                        artist: 'Drop Artist',
                        album: 'Drop Album',
                        artistId: 11,
                        albumId: 101,
                      ),
                    ),
                  ]).body;
            return StreamedResponse(Stream.value(utf8.encode(body)), 200);
          }
          if (req.url.path.endsWith('/tracks/uuid-drop/stream')) {
            if (!streamStarted.isCompleted) {
              streamStarted.complete();
            }
            return StreamedResponse(
              downloadStream.stream,
              200,
              contentLength: 999,
              headers: {
                'x-audio-extension': 'audio',
                'x-audio-bitrate-kbps': '320',
              },
            );
          }
          return StreamedResponse(Stream.value(utf8.encode('{}')), 404);
        }),
      );
      addTearDown(() async {
        await downloadStream.close();
      });

      final coverStore = await LocalCoverArtStore.create(
        apiClient: api,
        directoryProvider: () async => tempDir,
      );
      final c = createContainer(
        localCoverArtStore: coverStore,
        downloadDirectory: tempDir,
      );
      await waitForBuild(c);
      final syncNotifier = c.read(trackSyncProvider.notifier);
      await syncNotifier.sync();

      final manager = c.read(downloadManagerProvider);
      final track = TrackUI.fromQueryRow(
        (await db.getTrackByUuid('uuid-drop')).single,
      );
      await manager.enqueueTracks([track], quality: '320');
      await streamStarted.future;
      expect(manager.snapshot().single.isActive, isTrue);
      final downloadStatusVersion = manager.downloadStatusVersion.value;

      deleteMode = true;
      await syncNotifier.sync();
      await _whenChanged(
        manager.downloadStatusVersion,
        () => manager.downloadStatusVersion.value > downloadStatusVersion,
      );

      expect(manager.snapshot(), isEmpty);
      expect(await db.getTrackByUuid('uuid-drop'), isEmpty);
    });

    test(
      'delete preserves artists and albums still used by other tracks',
      () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([
              _upsert(
                1,
                _richTrackJson(
                  'uuid-one',
                  title: 'One Song',
                  artist: 'Shared Artist',
                  album: 'Shared Album',
                  artistId: 21,
                  albumId: 201,
                ),
              ),
              _upsert(
                2,
                _richTrackJson(
                  'uuid-two',
                  title: 'Two Song',
                  artist: 'Shared Artist',
                  album: 'Shared Album',
                  artistId: 21,
                  albumId: 201,
                ),
              ),
            ]),
          ),
        );

        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();

        installClient(
          'http://localhost:8000',
          MockClient((req) async => _changesResponse([_delete(3, 'uuid-one')])),
        );
        await notifier.sync();

        expect(
          (await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(),
          {'uuid-two'},
        );
        expect(
          await (db.select(db.albums)..where((a) => a.id.equals(201))).get(),
          hasLength(1),
        );
        expect(
          await (db.select(db.artists)..where((a) => a.id.equals(21))).get(),
          hasLength(1),
        );
        final sharedArtistFts = await db
            .customSelect(
              "SELECT rowid FROM fts_artists WHERE fts_artists MATCH '\"Shared\"*'",
            )
            .get();
        expect(sharedArtistFts, hasLength(1));
        final sharedAlbumFts = await db
            .customSelect(
              "SELECT rowid FROM fts_albums WHERE fts_albums MATCH '\"Shared\"*'",
            )
            .get();
        expect(sharedAlbumFts, hasLength(1));
      },
    );

    test('upsert move prunes old artist and album parents from FTS', () async {
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(
              1,
              _richTrackJson(
                'uuid-moving',
                title: 'Moving Song',
                artist: 'Old Artist',
                album: 'Old Album',
                artistId: 31,
                albumId: 301,
              ),
            ),
          ]),
        ),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(
              2,
              _richTrackJson(
                'uuid-moving',
                title: 'Moving Song',
                artist: 'New Artist',
                album: 'New Album',
                artistId: 32,
                albumId: 302,
              ),
            ),
          ]),
        ),
      );
      await notifier.sync();

      expect(
        await (db.select(db.artists)..where((a) => a.id.equals(31))).get(),
        isEmpty,
      );
      expect(
        await (db.select(db.albums)..where((a) => a.id.equals(301))).get(),
        isEmpty,
      );
      expect(
        await (db.select(db.artists)..where((a) => a.id.equals(32))).get(),
        hasLength(1),
      );
      expect(
        await (db.select(db.albums)..where((a) => a.id.equals(302))).get(),
        hasLength(1),
      );

      final oldArtistFts = await db
          .customSelect(
            "SELECT rowid FROM fts_artists WHERE fts_artists MATCH '\"Old\"*'",
          )
          .get();
      expect(oldArtistFts, isEmpty);
      final oldAlbumFts = await db
          .customSelect(
            "SELECT rowid FROM fts_albums WHERE fts_albums MATCH '\"Old\"*'",
          )
          .get();
      expect(oldAlbumFts, isEmpty);
      final newArtistFts = await db
          .customSelect(
            "SELECT rowid FROM fts_artists WHERE fts_artists MATCH '\"New\"*'",
          )
          .get();
      expect(newArtistFts, hasLength(1));
      final newAlbumFts = await db
          .customSelect(
            "SELECT rowid FROM fts_albums WHERE fts_albums MATCH '\"New\"*'",
          )
          .get();
      expect(newAlbumFts, hasLength(1));
    });

    test('upserts and deletes in one page apply in revision order', () async {
      // uuid-x is upserted then deleted within the same page → ends deleted.
      // uuid-y is deleted then re-upserted → ends present.
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(1, _trackJson('uuid-x')),
            _upsert(2, _trackJson('uuid-y')),
            _delete(3, 'uuid-y'),
            _delete(4, 'uuid-x'),
            _upsert(5, _trackJson('uuid-y')),
          ]),
        ),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      final present = (await db.select(db.tracks).get())
          .map((t) => t.uuidId)
          .toSet();
      expect(present, {'uuid-y'});
    });

    test('a delete on a later page is still applied', () async {
      // limit-1 style pagination: the delete lands on its own later page and
      // must not be missed (the old design only carried deletes on page 1).
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          if (call == 1) {
            return _changesResponse([
              _upsert(1, _trackJson('uuid-1')),
            ], nextCursor: 1);
          } else if (call == 2) {
            return _changesResponse([
              _upsert(2, _trackJson('uuid-2')),
            ], nextCursor: 2);
          }
          return _changesResponse([_delete(3, 'uuid-1')]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      expect(call, 3);
      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-2',
      });
    });

    test('advances by nextCursor even when a page yields no changes', () async {
      // Mirrors the server dropping all upserts on a full page (concurrent
      // deletes): changes is empty but nextCursor is non-null. The client must
      // advance to the cursor and keep paging, not loop forever on the same
      // after_revision.
      final afterParams = <String?>[];
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          afterParams.add(req.url.queryParameters['after_revision']);
          call++;
          if (call == 1) {
            return _changesResponse([], nextCursor: 5);
          }
          return _changesResponse([_upsert(6, _trackJson('uuid-6'))]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      expect(call, 2);
      expect(afterParams, ['0', '5']);
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 6);
    });

    test('resuming from a saved watermark is idempotent', () async {
      // Simulate a prior partial sync that applied up to revision 1.
      await SyncCursorStore(db).write(SyncStream.catalog, 1);
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          expect(req.url.queryParameters['after_revision'], '1');
          // The server replays revision 2 (a delete of a never-seen uuid) and
          // a fresh upsert; applying must not throw.
          return _changesResponse([
            _delete(2, 'uuid-unknown'),
            _upsert(3, _trackJson('uuid-3')),
          ]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-3',
      });
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 3);
    });

    test('first sync does not wipe existing local rows', () async {
      await db
          .into(db.tracks)
          .insert(
            TracksCompanion.insert(
              uuidId: 'existing-local-row',
              createdAt: 0,
              lastUpdated: 0,
            ),
          );

      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async =>
              _changesResponse([_upsert(1, _trackJson('uuid-current'))]),
        ),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'existing-local-row',
        'uuid-current',
      });
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 1);
    });

    test('upsert preserves local download metadata', () async {
      await db.customStatement(
        'INSERT INTO tracks '
        '(uuid_id, created_at, last_updated, file_path, '
        'downloaded_bitrate_kbps, file_size_bytes, downloaded_quality) '
        "VALUES ('uuid-downloaded', 1, 1, '/tmp/downloaded.m4a', 128, 4567, '128')",
      );

      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async =>
              _changesResponse([_upsert(1, _trackJson('uuid-downloaded'))]),
        ),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('uuid-downloaded'))).getSingle();
      expect(row.filePath, '/tmp/downloaded.m4a');
      expect(row.downloadedBitrateKbps, 128);
      expect(row.fileSizeBytes, 4567);
      expect(row.downloadedQuality, '128');
    });

    test(
      'upsert updates cover art id without clearing download metadata',
      () async {
        await db.customStatement(
          'INSERT INTO tracks '
          '(uuid_id, created_at, last_updated, file_path, '
          'downloaded_bitrate_kbps, file_size_bytes, downloaded_quality) '
          "VALUES ('uuid-cover', 1, 1, '/tmp/cover.m4a', 256, 8901, '256')",
        );

        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([
              _upsert(
                1,
                _richTrackJson(
                  'uuid-cover',
                  title: 'Cover Song',
                  artist: 'Cover Artist',
                  album: 'Cover Album',
                  artistId: 51,
                  albumId: 501,
                  hasAlbumArt: true,
                  coverArtId: 77,
                ),
              ),
            ]),
          ),
        );

        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();

        var meta = await (db.select(
          db.trackmetadata,
        )..where((t) => t.uuidId.equals('uuid-cover'))).getSingle();
        expect(meta.hasAlbumArt, isTrue);
        expect(meta.coverArtId, 77);

        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([
              _upsert(
                2,
                _richTrackJson(
                  'uuid-cover',
                  title: 'Cover Song',
                  artist: 'Cover Artist',
                  album: 'Cover Album',
                  artistId: 51,
                  albumId: 501,
                ),
              ),
            ]),
          ),
        );
        await notifier.sync();

        meta = await (db.select(
          db.trackmetadata,
        )..where((t) => t.uuidId.equals('uuid-cover'))).getSingle();
        expect(meta.hasAlbumArt, isFalse);
        expect(meta.coverArtId, isNull);

        final row = await (db.select(
          db.tracks,
        )..where((t) => t.uuidId.equals('uuid-cover'))).getSingle();
        expect(row.filePath, '/tmp/cover.m4a');
        expect(row.downloadedBitrateKbps, 256);
        expect(row.fileSizeBytes, 8901);
        expect(row.downloadedQuality, '256');
      },
    );

    test(
      'delete entry repairs queue sessions pointing at the deleted track',
      () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([
              _upsert(
                1,
                _richTrackJson(
                  'uuid-keep',
                  title: 'Keep',
                  artist: 'A',
                  album: 'AL',
                  artistId: 10,
                  albumId: 100,
                ),
              ),
              _upsert(
                2,
                _richTrackJson(
                  'uuid-drop',
                  title: 'Drop',
                  artist: 'B',
                  album: 'BL',
                  artistId: 11,
                  albumId: 101,
                ),
              ),
            ]),
          ),
        );

        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();

        final queueRepo = QueueRepository(db);
        final sessionId = await queueRepo.createSessionFromExplicitList(
          sourceType: 'search',
          trackUuids: const ['uuid-keep', 'uuid-drop'],
          currentIndex: 1,
        );
        final before = await queueRepo.getSessionSnapshot(sessionId);
        expect(before!.currentItem!.uuidId, 'uuid-drop');
        expect(await _playOrderCount(db, sessionId), 2);
        await queueRepo.updatePlaybackCursor(
          sessionId: sessionId,
          currentItemId: before.currentItem!.itemId,
          positionMs: 12345,
        );

        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([_delete(3, 'uuid-drop')]),
          ),
        );
        await notifier.sync();

        expect(await _playOrderCount(db, sessionId), 1);
        final sessionRow = await (db.select(
          db.queueSessions,
        )..where((s) => s.id.equals(sessionId))).getSingle();
        // 8-fix-r1 U20-B-01 (deliberately changed, was: current_item_id
        // NULL): the removed current was the last entry, repeat off, so the
        // cursor rests on the last survivor (the end of the queue).
        final keepItem = (await queueRepo.getSessionTracksInPlayOrder(
          sessionId,
        )).single;
        expect(keepItem.uuidId, 'uuid-keep');
        expect(sessionRow.currentItemId, keepItem.itemId);
        expect(sessionRow.currentPositionMs, 0);
        expect(
          c.read(trackSyncProvider).value!.endedQueueSessionIds,
          {sessionId},
          reason: 'the player is told the queue ended (no autoplay)',
        );
        // 6-R1-10: resume_main_item_id is never written (the column stays).
        expect(sessionRow.resumeMainItemId, isNull);

        final after = await queueRepo.getSessionSnapshot(sessionId);
        expect(after!.totalCount, 1);
        expect(after.currentItem!.uuidId, 'uuid-keep');
      },
    );

    test(
      'delete entry compacts queue positions after removing a non-tail track',
      () async {
        installClient(
          'http://localhost:8000',
          MockClient(
            (req) async => _changesResponse([
              _upsert(
                1,
                _richTrackJson(
                  'uuid-a',
                  title: 'A',
                  artist: 'Artist A',
                  album: 'Album A',
                  artistId: 41,
                  albumId: 401,
                ),
              ),
              _upsert(
                2,
                _richTrackJson(
                  'uuid-b',
                  title: 'B',
                  artist: 'Artist B',
                  album: 'Album B',
                  artistId: 42,
                  albumId: 402,
                ),
              ),
              _upsert(
                3,
                _richTrackJson(
                  'uuid-c',
                  title: 'C',
                  artist: 'Artist C',
                  album: 'Album C',
                  artistId: 43,
                  albumId: 403,
                ),
              ),
            ]),
          ),
        );

        final c = createContainer();
        await waitForBuild(c);
        final notifier = c.read(trackSyncProvider.notifier);
        await notifier.sync();

        final queueRepo = QueueRepository(db);
        final sessionId = await queueRepo.createSessionFromExplicitList(
          sourceType: 'search',
          trackUuids: const ['uuid-a', 'uuid-b', 'uuid-c'],
          currentIndex: 1,
        );
        expect(await _playPositions(db, sessionId), [0, 1, 2]);
        expect(await _canonicalPositions(db, sessionId), [0, 1, 2]);

        installClient(
          'http://localhost:8000',
          MockClient((req) async => _changesResponse([_delete(4, 'uuid-a')])),
        );
        await notifier.sync();

        expect(await _playPositions(db, sessionId), [0, 1]);
        expect(await _canonicalPositions(db, sessionId), [0, 1]);
        final entries = await queueRepo.getPlaybackEntries(sessionId);
        expect(entries.map((entry) => entry.uuidId).toList(), [
          'uuid-b',
          'uuid-c',
        ]);
        expect(entries.map((entry) => entry.playPosition).toList(), [0, 1]);
        expect(entries.map((entry) => entry.canonicalPosition).toList(), [
          0,
          1,
        ]);

        final after = await queueRepo.getSessionSnapshot(sessionId);
        expect(after!.currentItem!.uuidId, 'uuid-b');
        expect(after.currentItem!.playPosition, 0);
      },
    );
  });

  // 8-fix-r1 TR-DELETE-01 (spec §6: the tombstone path drives the player
  // reconcile and the download removal): each page commits on its own, so a
  // run that fails after a page of tombstones committed must still publish
  // what it changed (queue sessions, deleted uuids) and rebuild search.
  group('TR-DELETE-01: tombstones committed before a failure are published',
      () {
    late int sessionId;

    Response unauthorized() => Response(
          '{"detail":{"code":"invalid_token","message":"Sign in again."}}',
          401,
          headers: {'content-type': 'application/json'},
        );

    Future<TrackSyncNotifier> seedLibrary(ProviderContainer c) async {
      installClient(
        'http://localhost:8000',
        MockClient(
          (req) async => _changesResponse([
            _upsert(
              1,
              _richTrackJson('uuid-gone',
                  title: 'Vanishing Song',
                  artist: 'A',
                  album: 'AL',
                  artistId: 10,
                  albumId: 100),
            ),
            _upsert(
              2,
              _richTrackJson('uuid-keep',
                  title: 'Keep',
                  artist: 'B',
                  album: 'BL',
                  artistId: 11,
                  albumId: 101),
            ),
          ]),
        ),
      );
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();
      sessionId = await QueueRepository(db).createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['uuid-gone', 'uuid-keep'],
        currentIndex: 1,
      );
      return notifier;
    }

    /// Page 1 tombstones uuid-gone and points at a page 2, which [page2]
    /// answers.
    void tombstoneThen(Response Function() page2) {
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          if (call == 1) {
            return _changesResponse([_delete(3, 'uuid-gone')], nextCursor: 3);
          }
          return page2();
        }),
      );
    }

    Future<List<QueryRow>> ftsMatches() => db
        .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Vanishing\"*'")
        .get();

    test('a failed later page: the tombstone reaches the queue, downloads '
        'and search; the error is still published', () async {
      final c = createContainer();
      final notifier = await seedLibrary(c);
      final before = c.read(trackSyncProvider).value!;
      expect(await ftsMatches(), hasLength(1));

      tombstoneThen(() => Response('boom', 500));
      await notifier.sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId),
          ['uuid-keep'],
          reason: 'page 1 committed');
      expect(await SyncCursorStore(db).read(SyncStream.catalog), 3);
      final state = c.read(trackSyncProvider).value!;
      expect(state.error, isNotNull);
      expect(state.isSyncing, isFalse);
      expect(state.queueMutationVersion, before.queueMutationVersion + 1);
      expect(state.affectedQueueSessionIds, {sessionId});
      expect(state.downloadMutationVersion, before.downloadMutationVersion + 1);
      expect(state.deletedTrackUuids, {'uuid-gone'});
      expect(await ftsMatches(), isEmpty,
          reason: 'search no longer finds the deleted track');
    });

    test('a 401 on a later page: published too, and no error', () async {
      final c = createContainer();
      final notifier = await seedLibrary(c);
      final before = c.read(trackSyncProvider).value!;

      tombstoneThen(unauthorized);
      await notifier.sync();

      final state = c.read(trackSyncProvider).value!;
      expect(state.error, isNull);
      expect(state.queueMutationVersion, before.queueMutationVersion + 1);
      expect(state.affectedQueueSessionIds, {sessionId});
      expect(state.downloadMutationVersion, before.downloadMutationVersion + 1);
      expect(state.deletedTrackUuids, {'uuid-gone'});
      expect(await ftsMatches(), isEmpty);
    });

    // Review r1-fe-a #2: "ended" is the last landing's verdict, not a
    // union over pages: a later page that re-lands the session on an entry
    // queued meanwhile clears it.
    test('a later page that re-lands an ended session clears its ended '
        'mark', () async {
      installClient(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse([
              _upsert(1, _trackJson('uuid-a')),
              _upsert(2, _trackJson('uuid-b')),
              _upsert(3, _trackJson('uuid-n')),
            ])),
      );
      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();
      final queueRepo = QueueRepository(db);
      final id = await queueRepo.createSessionFromExplicitList(
          sourceType: 'search',
          trackUuids: const ['uuid-a', 'uuid-b'],
          currentIndex: 1);

      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          if (call == 1) {
            // b (current, last) goes: the session rests on a, ended.
            return _changesResponse([_delete(4, 'uuid-b')], nextCursor: 4);
          }
          // Between pages the user queues n; then a goes too: n is next.
          await queueRepo.appendManualItems(id, const ['uuid-n']);
          return _changesResponse([_delete(5, 'uuid-a')]);
        }),
      );
      await notifier.sync();

      final state = c.read(trackSyncProvider).value!;
      expect(state.affectedQueueSessionIds, {id});
      expect(state.endedQueueSessionIds, isEmpty);
    });

    // Review r2 8-R2-13: a fence means a reset is wiping the store; what an
    // earlier page committed must not queue a player reconcile or a download
    // removal against it. Only the error is published.
    test('a reset fence on a later page publishes only the error', () async {
      final c = createContainer();
      final notifier = await seedLibrary(c);
      final before = c.read(trackSyncProvider).value!;

      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          if (call == 1) {
            return _changesResponse([_delete(3, 'uuid-gone')], nextCursor: 3);
          }
          await ServerBindingRepository(db).fence(); // reset step 1
          return _changesResponse([_delete(4, 'uuid-keep')]);
        }),
      );
      await notifier.sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId),
          ['uuid-keep'],
          reason: 'page 1 committed; the fenced page 2 wrote nothing');
      final state = c.read(trackSyncProvider).value!;
      expect(state.isSyncing, isFalse);
      expect(state.error, isNotNull);
      expect(state.queueMutationVersion, before.queueMutationVersion);
      expect(state.downloadMutationVersion, before.downloadMutationVersion);
      expect(state.affectedQueueSessionIds, isEmpty);
      expect(state.deletedTrackUuids, isEmpty);
      expect(state.endedQueueSessionIds, isEmpty);
    });

    test('nothing committed: nothing published (unchanged rule)', () async {
      final c = createContainer();
      final notifier = await seedLibrary(c);
      final before = c.read(trackSyncProvider).value!;

      installClient('http://localhost:8000',
          MockClient((req) async => Response('boom', 500)));
      await notifier.sync();

      final state = c.read(trackSyncProvider).value!;
      expect(state.error, isNotNull);
      expect(state.queueMutationVersion, before.queueMutationVersion);
      expect(state.downloadMutationVersion, before.downloadMutationVersion);
      expect(state.affectedQueueSessionIds, isEmpty);
      expect(state.deletedTrackUuids, isEmpty);
      expect(await ftsMatches(), hasLength(1));
    });
  });

  group('TrackSyncNotifier.syncFresh', () {
    test('waits out an in-flight sync, then runs a fresh pull', () async {
      final events = <String>[];
      final firstHeld = Completer<void>();
      final firstArrived = Completer<void>();
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          final n = ++call;
          events.add('start$n');
          if (n == 1) {
            firstArrived.complete();
            await firstHeld.future;
          }
          events.add('end$n');
          return _changesResponse([
            _upsert(n, _trackJson('uuid-$n', revision: n)),
          ]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);

      final plain = notifier.sync();
      await firstArrived.future;
      var freshDone = false;
      final fresh = notifier.syncFresh().then((ok) {
        freshDone = true;
        return ok;
      });
      await pumpEventQueue();
      expect(freshDone, isFalse, reason: 'must wait for the in-flight pull');
      expect(call, 1, reason: 'no overlapping pull was started');

      firstHeld.complete();
      await plain;
      expect(await fresh, isTrue);
      expect(events, [
        'start1',
        'end1',
        'start2',
        'end2',
      ], reason: 'a second pull started only after the first finished');
      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-1',
        'uuid-2',
      });
    });

    test(
      'with nothing in flight runs exactly one pull and returns true',
      () async {
        var call = 0;
        installClient(
          'http://localhost:8000',
          MockClient((req) async {
            call++;
            return _changesResponse([_upsert(1, _trackJson('uuid-1'))]);
          }),
        );
        final c = createContainer();
        await waitForBuild(c);

        expect(await c.read(trackSyncProvider.notifier).syncFresh(), isTrue);
        expect(call, 1);
      },
    );

    test('offline returns false without a request', () async {
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          return _changesResponse(const []);
        }),
      );
      final c = createContainer(offline: true);
      await waitForBuild(c);

      expect(await c.read(trackSyncProvider.notifier).syncFresh(), isFalse);
      expect(call, 0);
    });

    test('a failed pull returns false and publishes the error', () async {
      installClient(
        'http://localhost:8000',
        MockClient((req) async => Response('boom', 500)),
      );
      final c = createContainer();
      await waitForBuild(c);

      expect(await c.read(trackSyncProvider.notifier).syncFresh(), isFalse);
      final state = c.read(trackSyncProvider).value!;
      expect(state.error, isNotNull);
      expect(state.isSyncing, isFalse);
    });

    test('concurrent syncFresh/sync calls never overlap a pull', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      var call = 0;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          call++;
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          // Held across several turns, so an overlapping pull would start.
          await pumpEventQueue();
          inFlight--;
          return _changesResponse(const []);
        }),
      );
      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);

      final results = await Future.wait([
        notifier.syncFresh(),
        notifier.syncFresh(),
        notifier.sync().then((_) => true),
        notifier.syncFresh(),
      ]);

      expect(maxInFlight, 1);
      expect(
        results,
        everyElement(isTrue),
        reason: 'every syncFresh caller got its own completed fresh pull',
      );
      expect(call, greaterThanOrEqualTo(2));
      expect(c.read(trackSyncProvider).value!.isSyncing, isFalse);
    });
  });

  // Was "Artist-rename orphan reproduction": written when app resume ran
  // no sync and the old artist stayed (other-issues row 22).
  group('an artist rename flushed through the edit outbox', () {
    test('flushing an artist rename, then resuming the app, removes the old '
        'artist from the browse grid', () async {
      // Establish Artist "Old" (id 31) locally exactly like a freshly
      // synced library: one track, one artist, one album.
      var patched = false;
      installClient(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PATCH') {
            patched = true;
            // The server accepts the rename and reassigns the track
            // server-side to a new Artist "New" (id 32), GC-ing Artist
            // "Old" (31) — reflected below on the next `/changes` pull,
            // which app-resume is what makes happen at all.
            return Response(
              jsonEncode({
                'uuid_id': 'uuid-moving',
                'revision': 2,
                'master_written': false,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (patched) {
            return _changesResponse([
              _upsert(
                2,
                _richTrackJson(
                  'uuid-moving',
                  title: 'Song',
                  artist: 'New',
                  album: 'Old Album',
                  artistId: 32,
                  albumId: 301,
                ),
              ),
            ]);
          }
          return _changesResponse([
            _upsert(
              1,
              _richTrackJson(
                'uuid-moving',
                title: 'Song',
                artist: 'Old',
                album: 'Old Album',
                artistId: 31,
                albumId: 301,
              ),
            ),
          ]);
        }),
      );
      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      // Sanity check: Artist "Old" is on the board after the initial sync.
      expect(
        await (db.select(db.artists)..where((a) => a.id.equals(31))).get(),
        hasLength(1),
      );

      // The user renames the track's artist via the real edit outbox — the
      // same seam Get Info uses — and the save completes successfully.
      final outbox = c.read(editOutboxProvider);
      await outbox.enqueue(
        uuidId: 'uuid-moving',
        edit: const MetadataEdit.empty().set('artist', 'New'),
        writeMode: EditWriteMode.dbOnly,
        baseRevision: 1,
      );
      await outbox.flush();
      expect(patched, isTrue);
      expect(await db.select(db.pendingEdits).get(), isEmpty);

      // The app is backgrounded and resumed — no network flap, no manual
      // navigation to a fresh Artists/Albums/Tracks page. Just the most
      // ordinary "user put their phone away and picked it back up" edge.
      await c.read(recoveryServiceProvider).runFor(RecoveryTrigger.appResume);

      // Artist "Old" has no tracks left after the rename. Only SyncService
      // repoints the local artist_id and prunes the parent row; app resume
      // runs a catalog sync (`_SyncRecoverable` fires on `appResume` and
      // `networkRecovered`), whose pull moves the track to Artist "New" and
      // removes Artist "Old", so its card goes.
      final oldArtist = await (db.select(
        db.artists,
      )..where((a) => a.id.equals(31))).get();
      expect(
        oldArtist,
        isEmpty,
        reason:
            'Artist "Old" has no remaining tracks after the rename; the '
            'sync that app resume runs prunes it.',
      );
    });
  });

  // Phase 8B.2a / D29: every successful sync requests an owned-file cleanup
  // pass, which retries rows an earlier attempt kept.
  test('a sync requests an owned-file cleanup pass', () async {
    installClient(
      'http://localhost:8000',
      MockClient((req) async => _changesResponse([])),
    );
    final c = createContainer(downloadDirectory: tempDir);
    await waitForBuild(c);
    final kept = File('${tempDir.path}/tracks/kept.audio')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    await db.transaction(
      () => c
          .read(ownedFileCleanupProvider)
          .enqueueInTransaction([kept.path], localBindingId: null),
    );
    await c.read(trackSyncProvider.notifier).sync();
    await c.read(ownedFileCleanupRunnerProvider).whenIdle();
    expect(kept.existsSync(), isFalse);
  });

  // The app's catalog sync hands the stored-cover removal to the sync: a
  // tombstone that removes the last download showing a cover deletes that
  // cover's stored file; a cover another download still shows stays.
  test('a tombstone sync deletes the stored cover no download shows any '
      'more and keeps one another download shows', () async {
    var tombstones = false;
    installClient(
      'http://localhost:8000',
      MockClient((req) async {
        if (req.url.pathSegments.last != 'changes') return Response('', 404);
        if (tombstones) {
          return _changesResponse([_delete(4, 'u1'), _delete(5, 'u2')]);
        }
        return _changesResponse([
          for (final (rev, uuid, cover) in [
            (1, 'u1', 5),
            (2, 'u2', 6),
            (3, 'u3', 6),
          ])
            _upsert(
              rev,
              _richTrackJson(uuid, title: 'Song $uuid', artist: 'Artist',
                  album: 'Album', artistId: 11, albumId: 101,
                  createdAt: 1000 + rev, hasAlbumArt: true, coverArtId: cover),
            ),
        ]);
      }),
    );
    final covers = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
      apiClient: api,
    );
    final c = createContainer(
        localCoverArtStore: covers, downloadDirectory: tempDir);
    await waitForBuild(c);
    final notifier = c.read(trackSyncProvider.notifier);
    await notifier.sync();
    for (final uuid in ['u1', 'u2', 'u3']) {
      final file = File('${tempDir.path}/tracks/$uuid.m4a')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(
        filePath: Value(file.path),
        fileSizeBytes: const Value(3),
        downloadedQuality: const Value('320'),
      ));
    }
    covers.fileFor(5).writeAsBytesSync([5]);
    covers.fileFor(6).writeAsBytesSync([6]);

    tombstones = true;
    await notifier.sync();

    expect((await db.select(db.tracks).get()).map((t) => t.uuidId), ['u3']);
    expect(covers.fileFor(5).existsSync(), isFalse,
        reason: 'no download shows cover 5 any more');
    expect(covers.fileFor(6).readAsBytesSync(), [6],
        reason: 'u3 is still downloaded and shows cover 6');
  });
  // 8B.2b / D25, spec §6 last paragraph: "Cancel in-flight/queued downloads
  // for tombstoned UUIDs and fence late completion against absent/current
  // track generation so it cannot restore a row/path" (8-U08, 8-C03 unit
  // halves), through the app's wiring: the tombstone sync publishes the
  // deleted UUIDs and the download manager fences them.
  group('8B.2b D25: downloads of a tombstoned track', () {
    List<String> audioFiles() {
      final dir = Directory('${tempDir.path}/tracks');
      if (!dir.existsSync()) return const [];
      return [
        for (final f in dir.listSync().whereType<File>())
          if (!f.path.endsWith('.partial')) f.path.split('/').last,
      ];
    }

    Map<String, dynamic> track(int rev, String uuid) => _upsert(
      rev,
      _richTrackJson(uuid, title: 'Song $uuid', artist: 'Artist',
          album: 'Album', artistId: 11, albumId: 101),
    );

    test('a queued job is dropped and never requested; the others go on',
        () async {
      const busy = ['k1', 'k2', 'k3', 'k4']; // WorkerPool.maxConcurrent
      var deleteMode = false;
      final held = StreamController<List<int>>.broadcast();
      addTearDown(held.close);
      final streamed = <String>[];
      final allBusyStreaming = Completer<void>();
      installClient(
        'http://localhost:8000',
        MockClient.streaming((req, _) async {
          final path = req.url.path;
          if (path.endsWith('/changes')) {
            final body = deleteMode
                ? _changesResponse([_delete(10, 'uuid-drop')]).body
                : _changesResponse([
                    for (var i = 0; i < busy.length; i++) track(i + 1, busy[i]),
                    track(5, 'uuid-drop'),
                  ]).body;
            return StreamedResponse(Stream.value(utf8.encode(body)), 200);
          }
          if (path.endsWith('/stream')) {
            streamed.add(req.url.pathSegments[1]);
            if (streamed.length == busy.length &&
                !allBusyStreaming.isCompleted) {
              allBusyStreaming.complete();
            }
            return StreamedResponse(held.stream, 200, contentLength: 999,
                headers: {'x-audio-extension': 'audio'});
          }
          return StreamedResponse(Stream.value(utf8.encode('{}')), 404);
        }),
      );
      final coverStore = await LocalCoverArtStore.create(
        apiClient: api,
        directoryProvider: () async => tempDir,
      );
      final c = createContainer(
          localCoverArtStore: coverStore, downloadDirectory: tempDir);
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      final manager = c.read(downloadManagerProvider);
      Future<TrackUI> ui(String u) async =>
          TrackUI.fromQueryRow((await db.getTrackByUuid(u)).single);
      await manager.enqueueTracks(
          [for (final u in [...busy, 'uuid-drop']) await ui(u)],
          quality: '320');
      await allBusyStreaming.future.timeout(const Duration(seconds: 5));
      final drop = manager.snapshot().singleWhere((j) => j.uuidId == 'uuid-drop');
      expect(drop.isQueued, isTrue);
      final version = manager.downloadStatusVersion.value;

      deleteMode = true;
      await notifier.sync();
      await _whenChanged(manager.downloadStatusVersion,
          () => manager.downloadStatusVersion.value > version);

      expect(manager.snapshot().map((j) => j.uuidId).toSet(), busy.toSet());
      expect(manager.snapshot().every((j) => j.isActive), isTrue);
      await pumpEventQueue();
      expect(streamed, isNot(contains('uuid-drop')));
      expect(await db.getTrackByUuid('uuid-drop'), isEmpty);
    });

    test('a download finishing after the tombstone committed restores no '
        'row and leaves no file', () async {
      var deleteMode = false;
      installClient(
        'http://localhost:8000',
        MockClient.streaming((req, _) async {
          final path = req.url.path;
          if (path.endsWith('/changes')) {
            final body = deleteMode
                ? _changesResponse([_delete(2, 'uuid-drop')]).body
                : _changesResponse([track(1, 'uuid-drop')]).body;
            return StreamedResponse(Stream.value(utf8.encode(body)), 200);
          }
          if (path.endsWith('/tracks/uuid-drop/stream')) {
            return StreamedResponse(Stream.value([1, 2, 3]), 200,
                contentLength: 3, headers: {'x-audio-extension': 'audio'});
          }
          return StreamedResponse(Stream.value(utf8.encode('{}')), 404);
        }),
      );
      final coverStore = await LocalCoverArtStore.create(
        apiClient: api,
        directoryProvider: () async => tempDir,
      );
      final c = createContainer(
          localCoverArtStore: coverStore, downloadDirectory: tempDir);
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      final manager = c.read(downloadManagerProvider);
      final atCommit = Completer<void>();
      final release = Completer<void>();
      manager.testHookBeforeDbWrite = (_) async {
        if (!atCommit.isCompleted) atCommit.complete();
        await release.future;
      };
      await manager.enqueueTracks(
          [TrackUI.fromQueryRow((await db.getTrackByUuid('uuid-drop')).single)],
          quality: '320');
      await atCommit.future;
      expect(audioFiles(), ['uuid-drop.audio'], reason: 'renamed, unrecorded');

      final version = manager.downloadStatusVersion.value;
      deleteMode = true;
      await notifier.sync(); // the tombstone commits while the worker waits
      expect(await db.getTrackByUuid('uuid-drop'), isEmpty);
      release.complete();
      // The tombstone's fence awaited the worker, then published.
      await _whenChanged(manager.downloadStatusVersion,
          () => manager.downloadStatusVersion.value > version);
      expect(manager.snapshot(), isEmpty);
      await c.read(ownedFileCleanupRunnerProvider).whenIdle();

      expect(await db.getTrackByUuid('uuid-drop'), isEmpty,
          reason: 'no row restored');
      expect(audioFiles(), isEmpty, reason: 'the late file is owned-cleaned');
      expect(await db.select(db.ownedFileCleanupEntries).get(), isEmpty);
    });
  });
}
