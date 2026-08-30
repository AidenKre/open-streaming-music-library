import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);

  final bool _value;

  @override
  bool build() => _value;
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

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition was not met before timeout');
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

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
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
  }) {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        tracksApiProvider.overrideWithValue(TracksApi()),
        offlineModeProvider.overrideWith(() => _StubOffline(offline)),
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
  }

  group('TrackSyncNotifier', () {
    test(
      'first sync requests after_revision=0, upserts, saves lastRevision',
      () async {
        final requestUrls = <Uri>[];
        ApiClient.initForTest(
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

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(SyncService.lastRevisionKey), 2);
      },
    );

    test(
      'upsert stores the per-track revision from the payload, and a later '
      'upsert overwrites it',
      () async {
        var call = 0;
        ApiClient.initForTest(
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
      },
    );

    test(
      'subsequent sync sends the stored revision as after_revision',
      () async {
        SharedPreferences.setMockInitialValues({
          SyncService.lastRevisionKey: 5,
        });
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
        ApiClient.initForTest(
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
        ApiClient.initForTest(
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

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(SyncService.lastRevisionKey), 3);
      },
    );

    test(
      're-upserting the same uuid updates rather than duplicating',
      () async {
        ApiClient.initForTest(
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
        ApiClient.initForTest(
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
      ApiClient.initForTest(
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
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          callCount++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _changesResponse([_upsert(1, _trackJson('uuid-1'))]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);

      final f1 = notifier.sync();
      final f2 = notifier.sync();
      await Future.wait([f1, f2]);

      expect(callCount, 1);
    });

    test(
      'refreshTrack cannot publish the same mutation version as a concurrent sync',
      () async {
        // Both operations locally delete a track, so each publishes a
        // mutation-version bump. The audio coordinator drops any state whose
        // version is <= the last one it saw, so two concurrent operations
        // publishing the SAME version silently lose one reconciliation.
        // refreshTrack must serialize with sync via the isSyncing guard.
        ApiClient.initForTest(
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

        // Slow /changes carrying a delete; single-track GET reports gone.
        ApiClient.initForTest(
          'http://localhost:8000',
          MockClient((req) async {
            if (req.url.path.endsWith('/changes')) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return _changesResponse([_delete(3, 'uuid-a')]);
            }
            return Response('', 404);
          }),
        );

        final syncFuture = notifier.sync();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final refreshedDuringSync = await notifier.refreshTrack('uuid-b');
        await syncFuture;

        // Serialized: the refresh is skipped while the sync is in flight
        // (its take_server marker is retried after the sync).
        expect(refreshedDuringSync, isFalse);
        expect(
          c.read(trackSyncProvider).value!.downloadMutationVersion,
          1,
        );

        final refreshedAfterSync = await notifier.refreshTrack('uuid-b');
        expect(refreshedAfterSync, isTrue);
        expect(
          c.read(trackSyncProvider).value!.downloadMutationVersion,
          2,
        );
        expect(await db.getTrackByUuid('uuid-b'), isEmpty);

        // No version was ever published twice.
        expect(publishedVersions.toSet().length, publishedVersions.length);
        expect(publishedVersions, [1, 2]);
      },
    );

    test('offline sync skip makes no API request', () async {
      var callCount = 0;
      ApiClient.initForTest(
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SyncService.lastRevisionKey), isNull);
    });

    test(
      'failed later page resumes from the last applied page cursor',
      () async {
        final afterParams = <String?>[];
        var call = 0;
        ApiClient.initForTest(
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
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(SyncService.lastRevisionKey), 1);
        expect(c.read(trackSyncProvider).value!.error, isNotNull);

        ApiClient.initForTest(
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
        expect(prefs.getInt(SyncService.lastRevisionKey), 2);
        expect(c.read(trackSyncProvider).value!.error, isNull);
      },
    );

    test(
      'malformed change payload leaves existing watermark unchanged',
      () async {
        SharedPreferences.setMockInitialValues({
          SyncService.lastRevisionKey: 5,
        });
        ApiClient.initForTest(
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
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(SyncService.lastRevisionKey), 5);
        expect(
          c.read(trackSyncProvider).value!.error,
          contains('FormatException'),
        );
      },
    );

    test('non-advancing nextCursor fails without changing watermark', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse(const [], nextCursor: 0)),
      );

      final c = createContainer();
      await waitForBuild(c);
      await c.read(trackSyncProvider.notifier).sync();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SyncService.lastRevisionKey), isNull);
      expect(
        c.read(trackSyncProvider).value!.error,
        contains('Invalid non-advancing changes cursor'),
      );
    });

    test(
      'mismatched change and track uuid leaves existing watermark unchanged',
      () async {
        SharedPreferences.setMockInitialValues({
          SyncService.lastRevisionKey: 5,
        });
        ApiClient.initForTest(
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
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(SyncService.lastRevisionKey), 5);
        expect(
          c.read(trackSyncProvider).value!.error,
          contains('Change uuid_id must match track uuid_id'),
        );
      },
    );

    test('a second sync adds newly-changed tracks to FTS', () async {
      ApiClient.initForTest(
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

      ApiClient.initForTest(
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
      ApiClient.initForTest(
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

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-keep',
        'uuid-drop',
      });
      final downloadedFile = File('${tempDir.path}/uuid-drop.audio')
        ..writeAsBytesSync([1, 2, 3]);
      await (db.update(
        db.tracks,
      )..where((t) => t.uuidId.equals('uuid-drop'))).write(
        TracksCompanion(
          filePath: Value(downloadedFile.path),
          downloadedBitrateKbps: const Value(320),
          fileSizeBytes: const Value(3),
          downloadedQuality: const Value('320'),
        ),
      );

      // Next sync streams the deletion.
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _changesResponse([_delete(3, 'uuid-drop')])),
      );
      await notifier.sync();

      expect((await db.select(db.tracks).get()).map((t) => t.uuidId).toSet(), {
        'uuid-keep',
      });
      expect(downloadedFile.existsSync(), isFalse);
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SyncService.lastRevisionKey), 3);
    });

    test('sync tombstones fence active download jobs', () async {
      var deleteMode = false;
      final downloadStream = StreamController<List<int>>();
      final streamStarted = Completer<void>();
      ApiClient.initForTest(
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
      await _waitFor(
        () => manager.downloadStatusVersion.value > downloadStatusVersion,
      );

      expect(manager.snapshot(), isEmpty);
      expect(await db.getTrackByUuid('uuid-drop'), isEmpty);
    });

    test(
      'delete preserves artists and albums still used by other tracks',
      () async {
        ApiClient.initForTest(
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

        ApiClient.initForTest(
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
      ApiClient.initForTest(
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

      ApiClient.initForTest(
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
      ApiClient.initForTest(
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
      ApiClient.initForTest(
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
      ApiClient.initForTest(
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SyncService.lastRevisionKey), 6);
    });

    test('resuming from a saved watermark is idempotent', () async {
      // Simulate a prior partial sync that applied up to revision 1.
      SharedPreferences.setMockInitialValues({SyncService.lastRevisionKey: 1});
      ApiClient.initForTest(
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SyncService.lastRevisionKey), 3);
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

      ApiClient.initForTest(
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SyncService.lastRevisionKey), 1);
    });

    test('upsert preserves local download metadata', () async {
      await db.customStatement(
        'INSERT INTO tracks '
        '(uuid_id, created_at, last_updated, file_path, '
        'downloaded_bitrate_kbps, file_size_bytes, downloaded_quality) '
        "VALUES ('uuid-downloaded', 1, 1, '/tmp/downloaded.m4a', 128, 4567, '128')",
      );

      ApiClient.initForTest(
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

        ApiClient.initForTest(
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

        ApiClient.initForTest(
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
        ApiClient.initForTest(
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
          resumeMainItemId: before.currentItem!.itemId,
          updateResumeMainItemId: true,
        );

        ApiClient.initForTest(
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
        expect(sessionRow.currentItemId, isNull);
        expect(sessionRow.currentPositionMs, 0);
        expect(sessionRow.resumeMainItemId, isNull);

        final after = await queueRepo.getSessionSnapshot(sessionId);
        expect(after!.totalCount, 1);
        expect(after.currentItem!.uuidId, 'uuid-keep');
      },
    );

    test(
      'delete entry compacts queue positions after removing a non-tail track',
      () async {
        ApiClient.initForTest(
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

        ApiClient.initForTest(
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

  group('Artist-rename orphan reproduction', () {
    test(
      'flushing an artist rename, then resuming the app, still leaves the '
      'old artist on the browse grid',
      () async {
        // Establish Artist "Old" (id 31) locally exactly like a freshly
        // synced library: one track, one artist, one album.
        var patched = false;
        ApiClient.initForTest(
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
        await c
            .read(recoveryServiceProvider)
            .runFor(RecoveryTrigger.appResume);

        // Desired: Artist "Old" has zero tracks left after the rename, so it
        // should no longer show on the browse grid. Actual: nothing ever
        // repointed the local artist_id FK or pruned the parent row — that
        // only happens inside SyncService, and app resume never triggers a
        // sync (`_SyncRecoverable` only fires on `networkRecovered`) — so the
        // orphaned card survives resume entirely.
        final oldArtist = await (db.select(
          db.artists,
        )..where((a) => a.id.equals(31))).get();
        expect(
          oldArtist,
          isEmpty,
          reason:
              'Artist "Old" has no remaining tracks after the rename '
              'flushed, but resuming the app never reconciles it — the '
              'orphaned card survives indefinitely until some other page '
              'happens to trigger a sync.',
        );
      },
    );
  });
}
