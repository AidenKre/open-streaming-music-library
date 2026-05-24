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
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/queue_warm_service.dart';

TrackUI _track(
  String uuid, {
  String? title,
  String? artist,
  int? coverArtId,
  String? filePath,
  int? downloadedBitrateKbps,
  String? downloadedQuality,
}) {
  return TrackUI(
    uuidId: uuid,
    createdAt: 0,
    lastUpdated: 0,
    title: title ?? 'Title $uuid',
    artist: artist ?? 'Artist',
    duration: 120,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: coverArtId != null,
    coverArtId: coverArtId,
    filePath: filePath,
    downloadedBitrateKbps: downloadedBitrateKbps,
    downloadedQuality: downloadedQuality,
  );
}

Future<void> _insertTrack(
  AppDatabase db,
  String uuid, {
  int? coverArtId,
  bool hasAlbumArt = false,
  String? filePath,
  int? downloadedBitrateKbps,
  String? downloadedQuality,
}) async {
  await db
      .into(db.tracks)
      .insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          filePath: Value(filePath),
          downloadedBitrateKbps: Value(downloadedBitrateKbps),
          downloadedQuality: Value(downloadedQuality),
        ),
      );
  await db
      .into(db.trackmetadata)
      .insert(
        TrackmetadataCompanion.insert(
          uuidId: uuid,
          duration: 120,
          bitrateKbps: 320,
          sampleRateHz: 44100,
          channels: 2,
          hasAlbumArt: Value(hasAlbumArt),
          coverArtId: Value(coverArtId),
        ),
      );
}

Future<DownloadManager> _waitForFinish(DownloadManager m) async {
  // Wait for all in-flight jobs to leave the active state.
  while (m.snapshot().any((j) => j.isActive || j.isQueued)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return m;
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('condition was not met in time');
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.stream);

  final Stream<List<int>> stream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      stream,
      200,
      contentLength: 10,
      headers: {'x-audio-extension': 'mp3'},
    );
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('download-manager-test');
    // Default mock — overridden per-test via buildManager(client: ...).
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((_) async => http.Response.bytes([7], 200)),
    );
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Installs [client] as the ApiClient transport for this test and returns
  /// a DownloadManager wired to it.
  DownloadManager buildManager({
    required http.Client client,
    bool Function()? isOfflineFn,
    void Function()? onNetworkFailure,
  }) {
    ApiClient.initForTest('http://test:8080', client);
    return DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      isOfflineFn: isOfflineFn,
      onNetworkFailure: onNetworkFailure,
    );
  }

  /// A response body stream that emits a chunk then fails — simulates a
  /// connection dropping after the headers have already arrived.
  Stream<List<int>> failingStream(Object error) async* {
    yield const [1, 2, 3];
    await Future<void>.delayed(const Duration(milliseconds: 1));
    throw error;
  }

  Future<void> waitUntilNotActive(DownloadManager m) async {
    while (m.snapshot().any((j) => j.isActive)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('enqueueTracks rejects invalid quality', () async {
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    expect(
      () => manager.enqueueTracks([_track('a')], quality: 'lossless-MQA'),
      throwsArgumentError,
    );
  });

  test('downloads a track and persists file_path', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((req) async {
        expect(req.url.path, '/tracks/abc/stream');
        expect(req.url.queryParameters['quality'], '320');
        return http.Response.bytes(
          [1, 2, 3, 4],
          200,
          headers: {'x-audio-bitrate-kbps': '320'},
        );
      }),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    final job = manager.snapshot().first;
    expect(job.isCompleted, isTrue);
    expect((job.status as Completed).sizeBytes, 4);

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
    expect(await File(row.filePath!).readAsBytes(), [1, 2, 3, 4]);
    // Bitrate from server header persisted.
    expect(row.downloadedBitrateKbps, 320);
  });

  test(
    'resetAndDeleteFiles deletes completed files and clears job history',
    () async {
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await _waitForFinish(manager);
      final path = (await db.select(db.tracks).getSingle()).filePath!;
      expect(File(path).existsSync(), isTrue);
      expect(manager.snapshot(), hasLength(1));

      await manager.resetAndDeleteFiles();

      expect(manager.snapshot(), isEmpty);
      expect(File(path).existsSync(), isFalse);
      expect(Directory(p.join(tempDir.path, 'tracks')).existsSync(), isFalse);
    },
  );

  test(
    'resetAndDeleteFiles cancels active workers before they persist',
    () async {
      await _insertTrack(db, 'active');
      final stream = StreamController<List<int>>();
      final manager = buildManager(client: _StreamingClient(stream.stream));
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('active')], quality: originalQuality);
      await _waitFor(() {
        return manager.snapshot().any((j) => j.isActive);
      });
      stream.add([1, 2, 3]);
      await _waitFor(() {
        return manager.snapshot().any((j) {
          final s = j.status;
          return s is Active && s.progress > 0;
        });
      });

      await manager.resetAndDeleteFiles();
      await stream.close();

      final row = await db.select(db.tracks).getSingle();
      expect(row.filePath, isNull);
      expect(manager.snapshot(), isEmpty);
      expect(Directory(p.join(tempDir.path, 'tracks')).existsSync(), isFalse);
    },
  );

  test(
    'reset before rename leaves no files and no file_path row',
    () async {
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      );
      addTearDown(manager.dispose);

      // Block the worker just before it renames the partial into place. Then
      // trigger reset; once reset completes, release the worker so it observes
      // the bumped generation and aborts the commit.
      final hookEntered = Completer<void>();
      final releaseHook = Completer<void>();
      manager.testHookBeforeRename = (_) async {
        if (!hookEntered.isCompleted) hookEntered.complete();
        await releaseHook.future;
      };

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await hookEntered.future;

      // Kick off the reset; it must finish even though the worker is paused
      // mid-commit (the partial download was already drained).
      final resetFuture = manager.resetAndDeleteFiles();
      // Yield once so resetAndDeleteFiles has a chance to bump the generation
      // before we let the hook proceed.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      releaseHook.complete();
      await resetFuture;
      await _waitForFinish(manager);

      final row = await db.select(db.tracks).getSingle();
      expect(row.filePath, isNull);
      expect(Directory(p.join(tempDir.path, 'tracks')).existsSync(), isFalse);
    },
  );

  test(
    'reset between rename and DB write deletes the orphan destination file',
    () async {
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      );
      addTearDown(manager.dispose);

      final hookEntered = Completer<void>();
      final releaseHook = Completer<void>();
      manager.testHookBeforeDbWrite = (_) async {
        if (!hookEntered.isCompleted) hookEntered.complete();
        await releaseHook.future;
      };

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await hookEntered.future;

      // At this point the rename has happened — the destination file exists
      // but no DB row references it yet.
      final tracksDir = Directory(p.join(tempDir.path, 'tracks'));
      final renamed = tracksDir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.partial'))
          .toList();
      expect(renamed, hasLength(1));
      final destinationPath = renamed.first.path;

      final resetFuture = manager.resetAndDeleteFiles();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      releaseHook.complete();
      await resetFuture;
      await _waitForFinish(manager);

      // _deleteKnownDownloadedFiles couldn't have caught this file (it had no
      // DB row at reset time). The commit guard must have cleaned it up.
      expect(File(destinationPath).existsSync(), isFalse);
      final row = await db.select(db.tracks).getSingle();
      expect(row.filePath, isNull);
    },
  );

  test('enqueueTracks yields the event loop before completing (async I/O)', () async {
    // Proves the existence check is genuinely async: a microtask interleaved
    // between calling enqueueTracks and awaiting it must observe the call as
    // not-yet-complete. A blocking existsSync() would complete synchronously
    // and the interleaved flag would already be true.
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    final tracks = <TrackUI>[];
    for (var i = 0; i < 30; i++) {
      final filePath = p.join(tempDir.path, 'present-$i.audio');
      await File(filePath).writeAsBytes([1]);
      await _insertTrack(db, 'present-$i', filePath: filePath);
      tracks.add(_track('present-$i').copyWithFilePath(filePath));
    }

    var completed = false;
    final future = manager.enqueueTracks(tracks, quality: '320')
        .then((_) => completed = true);
    // After kicking off enqueueTracks we yield exactly one microtask. If the
    // body were synchronous-blocking, `completed` would already be true here.
    await Future<void>.value();
    expect(completed, isFalse,
        reason: 'enqueueTracks must yield between sync setup and async I/O');
    await future;
    expect(completed, isTrue);
    expect(manager.snapshot(), isEmpty);
  });

  test('downloadedUuidsForUuids uses async I/O for existence checks', () async {
    // Same async-ness assertion as above, but for the second site that was
    // converted from existsSync() to await file.exists().
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    final uuids = <String>[];
    for (var i = 0; i < 10; i++) {
      final filePath = p.join(tempDir.path, 'p-$i.audio');
      await File(filePath).writeAsBytes([1]);
      await _insertTrack(db, 'p-$i', filePath: filePath);
      uuids.add('p-$i');
    }

    var completed = false;
    final future = manager.downloadedUuidsForUuids(uuids)
        .then((set) {
      completed = true;
      return set;
    });
    await Future<void>.value();
    expect(completed, isFalse,
        reason: 'downloadedUuidsForUuids must not block on existsSync');
    final result = await future;
    expect(result, equals(uuids.toSet()));
  });

  test('transcoded response (m4a header) saves as .m4a', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient(
        (_) async => http.Response.bytes(
          [1],
          200,
          headers: {'x-audio-extension': 'm4a'},
        ),
      ),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '128');
    await _waitForFinish(manager);

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, endsWith('.m4a'));
  });

  test(
    'passthrough response on transcoded quality keeps the source extension',
    () async {
      // Backend returns the original MP3 when the source is already at or
      // below the requested bitrate. The saved file must use the header's
      // extension — assuming `.m4a` here would mislabel the bytes.
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient(
          (_) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {
              'x-audio-extension': 'mp3',
              'x-audio-bitrate-kbps': '96',
            },
          ),
        ),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await _waitForFinish(manager);

      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, endsWith('.mp3'));
    },
  );

  test(
    'original quality uses X-Audio-Extension header for extension',
    () async {
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient(
          (_) async => http.Response.bytes(
            [1, 2],
            200,
            headers: {'x-audio-extension': 'flac'},
          ),
        ),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('abc')], quality: originalQuality);
      await _waitForFinish(manager);

      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, endsWith('.flac'));
    },
  );

  test(
    'stores downloaded_bitrate_kbps from X-Audio-Bitrate-Kbps header',
    () async {
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient(
          (_) async => http.Response.bytes(
            [1],
            200,
            headers: {'x-audio-bitrate-kbps': '96'},
          ),
        ),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await _waitForFinish(manager);

      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.downloadedBitrateKbps, 96);
    },
  );

  test('downloaded_bitrate_kbps is null when header absent', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.downloadedBitrateKbps, isNull);
  });

  test('original quality falls back to .audio when header absent', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: originalQuality);
    await _waitForFinish(manager);

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, endsWith('.audio'));
  });

  test('uses no quality query for the original preset', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((req) async {
        expect(req.url.queryParameters, isEmpty);
        return http.Response.bytes([1], 200);
      }),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: originalQuality);
    await _waitForFinish(manager);
  });

  test('skips tracks already downloaded', () async {
    final existingPath = p.join(tempDir.path, 'existing.audio');
    await File(existingPath).writeAsBytes([9, 9]);
    await _insertTrack(db, 'abc', filePath: existingPath);

    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([
      _track('abc').copyWithFilePath(existingPath),
    ], quality: '320');
    expect(manager.snapshot(), isEmpty);
  });

  test(
    'enqueueTracks default path skips already-downloaded tracks regardless of '
    'requested quality',
    () async {
      // Track is on disk at 128 kbps but the caller asks for 320 — the
      // default-quality download path must preserve the existing file (this
      // is the documented contract; the explicit-quality path is what
      // re-downloads).
      final existingPath = p.join(tempDir.path, 'existing.audio');
      await File(existingPath).writeAsBytes([9, 9]);
      await _insertTrack(
        db,
        'abc',
        filePath: existingPath,
        downloadedBitrateKbps: 128,
      );

      var requestCount = 0;
      final manager = buildManager(
        client: MockClient((_) async {
          requestCount++;
          return http.Response.bytes([1], 200);
        }),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([
        _track(
          'abc',
          filePath: existingPath,
          downloadedBitrateKbps: 128,
        ),
      ], quality: '320');

      expect(manager.snapshot(), isEmpty);
      expect(requestCount, 0);
      // File and bitrate untouched.
      expect(File(existingPath).existsSync(), isTrue);
      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, existingPath);
      expect(row.downloadedBitrateKbps, 128);
    },
  );

  test(
    'enqueueTracksAtQuality skips when stored bitrate matches requested',
    () async {
      final existingPath = p.join(tempDir.path, 'existing.audio');
      await File(existingPath).writeAsBytes([9, 9]);
      await _insertTrack(
        db,
        'abc',
        filePath: existingPath,
        downloadedBitrateKbps: 320,
      );

      var requestCount = 0;
      final manager = buildManager(
        client: MockClient((_) async {
          requestCount++;
          return http.Response.bytes([1], 200);
        }),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracksAtQuality([
        _track(
          'abc',
          filePath: existingPath,
          downloadedBitrateKbps: 320,
        ),
      ], quality: '320');

      expect(manager.snapshot(), isEmpty);
      expect(requestCount, 0);
      // File and bitrate untouched.
      expect(File(existingPath).existsSync(), isTrue);
      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, existingPath);
      expect(row.downloadedBitrateKbps, 320);
    },
  );

  test(
    'enqueueTracksAtQuality deletes stale file and re-downloads when bitrate '
    'differs',
    () async {
      final existingPath = p.join(tempDir.path, 'existing.audio');
      await File(existingPath).writeAsBytes([9, 9, 9, 9]);
      await _insertTrack(
        db,
        'abc',
        filePath: existingPath,
        downloadedBitrateKbps: 128,
      );

      var requestCount = 0;
      final manager = buildManager(
        client: MockClient((req) async {
          requestCount++;
          expect(req.url.queryParameters['quality'], '320');
          return http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {'x-audio-bitrate-kbps': '320'},
          );
        }),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracksAtQuality([
        _track(
          'abc',
          filePath: existingPath,
          downloadedBitrateKbps: 128,
        ),
      ], quality: '320');
      await _waitForFinish(manager);

      // The stale 128 kbps file must be gone.
      expect(File(existingPath).existsSync(), isFalse);
      // The server was hit.
      expect(requestCount, 1);
      // The job completed and the row now points at the new 320 kbps file.
      final job = manager.snapshot().first;
      expect(job.isCompleted, isTrue);
      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, isNotNull);
      expect(row.filePath, isNot(existingPath));
      expect(File(row.filePath!).existsSync(), isTrue);
      expect(row.downloadedBitrateKbps, 320);
    },
  );

  test(
    'enqueueTracksAtQuality always re-downloads when quality is original',
    () async {
      // The source's true bitrate isn't known to the client, so an
      // already-downloaded file at any bitrate must NOT match a request for
      // `original` — we conservatively re-download. Regressing this branch
      // (returning true for original) would silently restore the old no-op
      // bug for users picking "Download at Original" on a 320 kbps copy.
      final existingPath = p.join(tempDir.path, 'existing.audio');
      await File(existingPath).writeAsBytes([5, 5, 5]);
      await _insertTrack(
        db,
        'abc',
        filePath: existingPath,
        downloadedBitrateKbps: 320,
      );

      var requestCount = 0;
      final manager = buildManager(
        client: MockClient((req) async {
          requestCount++;
          expect(req.url.queryParameters.containsKey('quality'), isFalse);
          return http.Response.bytes(
            [7, 7, 7],
            200,
            headers: {'x-audio-extension': 'flac'},
          );
        }),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracksAtQuality([
        _track(
          'abc',
          filePath: existingPath,
          downloadedBitrateKbps: 320,
        ),
      ], quality: originalQuality);
      await _waitForFinish(manager);

      expect(File(existingPath).existsSync(), isFalse);
      expect(requestCount, 1);
      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, isNotNull);
      expect(row.filePath, isNot(existingPath));
    },
  );

  test(
    'enqueueTracksAtQuality is idempotent for passthrough downloads',
    () async {
      // Source is 96 kbps; user asks for "Download at 320". The backend
      // (correctly) returns the 96 kbps original, so the stored
      // downloaded_bitrate_kbps is 96 but downloaded_quality is '320'. A
      // second "Download at 320" must NOT delete and redownload — the file
      // already represents what the user asked for.
      await _insertTrack(db, 'abc');
      var requestCount = 0;
      final manager = buildManager(
        client: MockClient((req) async {
          requestCount++;
          expect(req.url.queryParameters['quality'], '320');
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {
              'x-audio-bitrate-kbps': '96',
              'x-audio-extension': 'mp3',
            },
          );
        }),
      );
      addTearDown(manager.dispose);

      // First call downloads.
      await manager.enqueueTracksAtQuality(
        [_track('abc')],
        quality: '320',
      );
      await _waitForFinish(manager);
      expect(requestCount, 1);

      final firstRow = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(firstRow.filePath, isNotNull);
      expect(firstRow.downloadedBitrateKbps, 96);
      expect(firstRow.downloadedQuality, '320');
      final firstPath = firstRow.filePath!;

      // Rehydrate the TrackUI from the DB so the second call sees the stored
      // downloaded_quality (same path the UI uses).
      final states = await db.getTrackDownloadStates(['abc']);
      final rehydrated = _track(
        'abc',
        filePath: states['abc']!.filePath,
        downloadedBitrateKbps: states['abc']!.downloadedBitrateKbps,
        downloadedQuality: states['abc']!.downloadedQuality,
      );
      manager.clearFinished();

      // Second call must be a no-op.
      await manager.enqueueTracksAtQuality([rehydrated], quality: '320');
      await _waitForFinish(manager);

      expect(requestCount, 1, reason: 'no second download should fire');
      expect(File(firstPath).existsSync(), isTrue);
      final secondRow = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(secondRow.filePath, firstPath);
    },
  );

  test('recovers from a transient 503 on the audio stream', () async {
    await _insertTrack(db, 'abc');
    var calls = 0;
    final manager = buildManager(
      client: MockClient((req) async {
        calls++;
        expect(req.url.path, '/tracks/abc/stream');
        if (calls == 1) return http.Response('try again', 503);
        return http.Response.bytes(
          [1, 2, 3, 4],
          200,
          headers: {'x-audio-bitrate-kbps': '320'},
        );
      }),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    expect(
      calls,
      2,
      reason: 'request factory must be invoked once per attempt',
    );
    final job = manager.snapshot().first;
    expect(job.isCompleted, isTrue);

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
    expect(await File(row.filePath!).readAsBytes(), [1, 2, 3, 4]);
  });

  test('cover-art FS failure does not fail the audio job', () async {
    const coverArtId = 555;
    await _insertTrack(db, 'abc', coverArtId: coverArtId, hasAlbumArt: true);

    // Pre-create a non-empty directory where the cover art file would land
    // so the LocalCoverArtStore's rename throws FileSystemException.
    final blockingDir = Directory(
      p.join(coverStore.directory.path, '$coverArtId.bin'),
    );
    await blockingDir.create(recursive: true);
    await File(p.join(blockingDir.path, 'inside')).writeAsBytes([0]);

    final manager = buildManager(
      client: MockClient((req) async {
        if (req.url.path == '/tracks/abc/stream') {
          return http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {'x-audio-bitrate-kbps': '320'},
          );
        }
        if (req.url.path == '/cover_art/$coverArtId') {
          return http.Response.bytes([9, 9, 9], 200);
        }
        return http.Response('unexpected ${req.url.path}', 404);
      }),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    final job = manager.snapshot().first;
    expect(
      job.isCompleted,
      isTrue,
      reason: 'cover-art FS failure must not fail the audio job',
    );

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
  });

  test(
    'failed downloads surface as failed jobs and leave file_path null',
    () async {
      await _insertTrack(db, 'abc');
      final manager = buildManager(
        client: MockClient((_) async => http.Response('boom', 500)),
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await _waitForFinish(manager);

      final job = manager.snapshot().first;
      expect(job.isFailed, isTrue);

      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      expect(row.filePath, isNull);
    },
  );

  test(
    'a mid-stream network failure re-queues the job and reports offline',
    () async {
      await _insertTrack(db, 'abc');
      var offline = false;
      final manager = buildManager(
        client: MockClient.streaming(
          (req, _) async => http.StreamedResponse(
            failingStream(const SocketException('connection reset')),
            200,
            contentLength: 999,
          ),
        ),
        // Once offline is reported the pump pauses, so the re-queued job stays
        // queued instead of being retried into a tight loop.
        isOfflineFn: () => offline,
        onNetworkFailure: () => offline = true,
      );
      addTearDown(manager.dispose);

      await manager.enqueueTracks([_track('abc')], quality: '320');
      await waitUntilNotActive(manager);

      expect(offline, isTrue);
      final job = manager.snapshot().first;
      expect(job.isQueued, isTrue);
    },
  );

  test('a non-network mid-stream failure fails the job', () async {
    await _insertTrack(db, 'abc');
    var networkReported = false;
    final manager = buildManager(
      client: MockClient.streaming(
        (req, _) async => http.StreamedResponse(
          failingStream(const FormatException('corrupt payload')),
          200,
          contentLength: 999,
        ),
      ),
      onNetworkFailure: () => networkReported = true,
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    expect(networkReported, isFalse);
    expect(manager.snapshot().first.isFailed, isTrue);
  });

  test('queued jobs wait while offline and resume on recovery', () async {
    await _insertTrack(db, 'abc');
    var offline = true;
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      isOfflineFn: () => offline,
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(manager.snapshot().first.isQueued, isTrue);

    offline = false;
    manager.resumeIfPaused();
    await _waitForFinish(manager);
    expect(manager.snapshot().first.isCompleted, isTrue);
  });

  test('cancelQueued removes a queued job before it runs', () async {
    final gate = Completer<void>();
    final manager = buildManager(
      client: MockClient.streaming((req, _) async {
        await gate.future;
        return http.StreamedResponse(Stream<List<int>>.empty(), 500);
      }),
    );
    // Drain the workers cleanly so notifyListeners isn't called post-dispose.
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await _waitForFinish(manager);
      manager.dispose();
    });

    // Insert 6 tracks; 4 will be active, 2 queued.
    for (var i = 0; i < 6; i++) {
      await _insertTrack(db, 't$i');
    }
    final tracks = [for (var i = 0; i < 6; i++) _track('t$i')];
    await manager.enqueueTracks(tracks, quality: '320');

    manager.cancelQueued('t5');
    expect(manager.snapshot().any((j) => j.uuidId == 't5'), isFalse);
  });

  test(
    'cancelQueued is a no-op for an already-active or unknown uuid',
    () async {
      final manager = buildManager(
        client: MockClient((_) async => http.Response.bytes([1], 200)),
      );
      addTearDown(manager.dispose);

      await _insertTrack(db, 'abc');
      await manager.enqueueTracks([_track('abc')], quality: '320');
      await _waitForFinish(manager);

      // No throw on unknown id, no change to the snapshot.
      final before = manager.snapshot().length;
      manager.cancelQueued('unknown');
      manager.cancelQueued('abc');
      expect(manager.snapshot().length, before);
    },
  );

  test('clearFinished drops completed jobs', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    expect(
      manager.snapshot().where((j) => j.isCompleted),
      isNotEmpty,
    );

    manager.clearFinished();
    expect(manager.snapshot(), isEmpty);
  });

  test('deleteDownload removes the file and clears file_path', () async {
    final localPath = p.join(tempDir.path, 'local.audio');
    await File(localPath).writeAsBytes([1, 2, 3]);
    await _insertTrack(db, 'abc', filePath: localPath);

    final manager = buildManager(
      client: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(manager.dispose);

    await manager.deleteDownload('abc');

    expect(File(localPath).existsSync(), isFalse);
    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, isNull);
  });

  test('deleteDownload tolerates a missing file on disk', () async {
    final missingPath = p.join(tempDir.path, 'missing.audio');
    await _insertTrack(db, 'abc', filePath: missingPath);

    final manager = buildManager(
      client: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(manager.dispose);

    await manager.deleteDownload('abc');

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, isNull);
  });

  test(
    'downloadedUuidsForUuids only includes uuids whose file is on disk',
    () async {
      final present = p.join(tempDir.path, 'present.audio');
      final missing = p.join(tempDir.path, 'missing.audio');
      await File(present).writeAsBytes([1]);
      await _insertTrack(db, 'present', filePath: present);
      await _insertTrack(db, 'missing', filePath: missing);
      await _insertTrack(db, 'never');

      final manager = buildManager(
        client: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(manager.dispose);

      final result = await manager.downloadedUuidsForUuids([
        'present',
        'missing',
        'never',
        'unknown',
      ]);
      expect(result, {'present'});
    },
  );

  test('successful downloads bump downloadStatusVersion', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    final before = manager.downloadStatusVersion.value;
    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    expect(manager.downloadStatusVersion.value, greaterThan(before));
  });

  test('deleteDownload bumps downloadStatusVersion', () async {
    final path = p.join(tempDir.path, 'foo.audio');
    await File(path).writeAsBytes([1]);
    await _insertTrack(db, 'abc', filePath: path);

    final manager = buildManager(
      client: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(manager.dispose);

    final before = manager.downloadStatusVersion.value;
    await manager.deleteDownload('abc');
    expect(manager.downloadStatusVersion.value, greaterThan(before));
  });

  test(
    'enqueueTracks calls scheduleWarmUuids when warmService is provided',
    () async {
      final capturedUuids = <List<String>>[];
      final capturedQualities = <String>[];
      final fakeWarm = _RecordingWarmService(
        onWarmUuids: (uuids, quality) {
          capturedUuids.add(uuids);
          capturedQualities.add(quality);
        },
      );

      ApiClient.initForTest(
        'http://test:8080',
        MockClient(
          (_) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {
              'content-type': 'audio/mp4',
              'x-audio-extension': 'm4a',
              'x-audio-bitrate-kbps': '128',
            },
          ),
        ),
      );
      final manager = DownloadManager(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        warmService: fakeWarm,
        streamQualityFn: () => '256',
      );
      addTearDown(manager.dispose);

      final tracks = [_track('uuid-1'), _track('uuid-2')];
      await manager.enqueueTracks(tracks, quality: '128');
      await _waitForFinish(manager);

      // scheduleWarmUuids should have been called once with both UUIDs and the
      // stream quality (not the download quality).
      expect(capturedUuids, hasLength(1));
      expect(capturedUuids.first, containsAll(['uuid-1', 'uuid-2']));
      expect(capturedQualities.first, '256');
    },
  );
}

/// A [QueueWarmService] subclass that records [scheduleWarmUuids] calls.
class _RecordingWarmService extends QueueWarmService {
  final void Function(List<String> uuids, String quality) onWarmUuids;

  _RecordingWarmService({required this.onWarmUuids})
    : super(queueRepo: _NoopQueueRepo());

  @override
  void scheduleWarmUuids(List<String> trackUuids, {required String quality}) {
    onWarmUuids(trackUuids, quality);
  }
}

class _NoopQueueRepo implements QueueRepository {
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

extension on TrackUI {
  TrackUI copyWithFilePath(String? filePath) => TrackUI(
    uuidId: uuidId,
    filePath: filePath,
    createdAt: createdAt,
    lastUpdated: lastUpdated,
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    artistId: artistId,
    albumId: albumId,
    year: year,
    date: date,
    genre: genre,
    trackNumber: trackNumber,
    discNumber: discNumber,
    codec: codec,
    duration: duration,
    bitrateKbps: bitrateKbps,
    sampleRateHz: sampleRateHz,
    channels: channels,
    hasAlbumArt: hasAlbumArt,
    coverArtId: coverArtId,
    downloadedBitrateKbps: downloadedBitrateKbps,
    downloadedQuality: downloadedQuality,
  );
}
