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

TrackUI _track(String uuid, {String? title, String? artist, int? coverArtId}) {
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
  );
}

Future<void> _insertTrack(
  AppDatabase db,
  String uuid, {
  int? coverArtId,
  bool hasAlbumArt = false,
  String? filePath,
}) async {
  await db.into(db.tracks).insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          filePath: Value(filePath),
        ),
      );
  await db.into(db.trackmetadata).insert(
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
  while (m.snapshot().any((j) => j.state == DownloadState.active ||
      j.state == DownloadState.queued)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return m;
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
  DownloadManager buildManager({required http.Client client}) {
    ApiClient.initForTest('http://test:8080', client);
    return DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
    );
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
    expect(job.state, DownloadState.completed);
    expect(job.progress, 1.0);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
    expect(await File(row.filePath!).readAsBytes(), [1, 2, 3, 4]);
    // Transcoded quality → always .m4a regardless of response headers.
    expect(row.filePath, endsWith('.m4a'));
    // Bitrate from server header persisted.
    expect(row.downloadedBitrateKbps, 320);
  });

  test('transcoded quality always saves as .m4a', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes(
        [1],
        200,
        headers: {'x-audio-extension': 'flac'}, // header should be ignored
      )),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '128');
    await _waitForFinish(manager);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, endsWith('.m4a'));
  });

  test('original quality uses X-Audio-Extension header for extension', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes(
        [1, 2],
        200,
        headers: {'x-audio-extension': 'flac'},
      )),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: originalQuality);
    await _waitForFinish(manager);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, endsWith('.flac'));
  });

  test('stores downloaded_bitrate_kbps from X-Audio-Bitrate-Kbps header',
      () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes(
        [1],
        200,
        headers: {'x-audio-bitrate-kbps': '96'},
      )),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.downloadedBitrateKbps, 96);
  });

  test('downloaded_bitrate_kbps is null when header absent', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
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

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
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

    await manager.enqueueTracks(
      [_track('abc').copyWithFilePath(existingPath)],
      quality: '320',
    );
    expect(manager.snapshot(), isEmpty);
  });

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

    expect(calls, 2,
        reason: 'request factory must be invoked once per attempt');
    final job = manager.snapshot().first;
    expect(job.state, DownloadState.completed);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
    expect(await File(row.filePath!).readAsBytes(), [1, 2, 3, 4]);
  });

  test('cover-art FS failure does not fail the audio job', () async {
    const coverArtId = 555;
    await _insertTrack(db, 'abc',
        coverArtId: coverArtId, hasAlbumArt: true);

    // Pre-create a non-empty directory where the cover art file would land
    // so the LocalCoverArtStore's rename throws FileSystemException.
    final blockingDir =
        Directory(p.join(coverStore.directory.path, '$coverArtId.bin'));
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
    expect(job.state, DownloadState.completed,
        reason: 'cover-art FS failure must not fail the audio job');

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
  });

  test('failed downloads surface as failed jobs and leave file_path null',
      () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response('boom', 500)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    final job = manager.snapshot().first;
    expect(job.state, DownloadState.failed);

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, isNull);
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

  test('cancelQueued is a no-op for an already-active or unknown uuid',
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
  });

  test('clearFinished drops completed jobs', () async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(manager.dispose);

    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _waitForFinish(manager);

    expect(
      manager.snapshot().where((j) => j.state == DownloadState.completed),
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
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
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

    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('abc')))
        .getSingle();
    expect(row.filePath, isNull);
  });

  test('downloadedUuidsForUuids only includes uuids whose file is on disk',
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

    final result = await manager
        .downloadedUuidsForUuids(['present', 'missing', 'never', 'unknown']);
    expect(result, {'present'});
  });

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

  test('enqueueTracks calls scheduleWarmUuids when warmService is provided',
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
      MockClient((_) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {
              'content-type': 'audio/mp4',
              'x-audio-extension': 'm4a',
              'x-audio-bitrate-kbps': '128',
            },
          )),
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
  });
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
      );
}
