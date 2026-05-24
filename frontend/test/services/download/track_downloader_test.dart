import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/local_cover_art_store.dart';

Future<void> _insertTrack(AppDatabase db, String uuid) async {
  await db
      .into(db.tracks)
      .insert(
        TracksCompanion.insert(uuidId: uuid, createdAt: 0, lastUpdated: 0),
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
        ),
      );
}

DownloadJob _job(String uuidId, {String quality = '320'}) => DownloadJob(
  uuidId: uuidId,
  title: 'title',
  artist: 'artist',
  quality: quality,
  status: const Queued(),
);

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('track_downloader_test_');
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((_) async => http.Response.bytes([1], 200)),
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

  TrackDownloader buildDownloader(http.Client client) {
    ApiClient.initForTest('http://test:8080', client);
    return TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: ApiClient.instance,
    );
  }

  test('happy path: writes file, commits to DB, returns success', () async {
    await _insertTrack(db, 'abc');
    final downloader = buildDownloader(
      MockClient((req) async {
        return http.Response.bytes(
          [1, 2, 3, 4, 5],
          200,
          headers: {'x-audio-bitrate-kbps': '320'},
        );
      }),
    );

    final progress = <double>[];
    final outcome = await downloader.download(
      job: _job('abc'),
      generationCheck: () => true,
      onProgress: progress.add,
      registerCanceller: (_) {},
      unregisterCanceller: () {},
    );

    expect(outcome.kind, DownloadOutcomeKind.success);
    expect(outcome.sizeBytes, 5);

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.filePath, isNotNull);
    expect(File(row.filePath!).existsSync(), isTrue);
    expect(row.downloadedBitrateKbps, 320);
    expect(row.fileSizeBytes, 5);
  });

  test(
    'generation-check turning false before headers cancels the download',
    () async {
      await _insertTrack(db, 'abc');
      final downloader = buildDownloader(
        MockClient((req) async => http.Response.bytes([1, 2, 3], 200)),
      );

      var generationValid = true;
      // Flip the gate before the very first generation check
      // (which is the pre-HTTP check).
      generationValid = false;

      final outcome = await downloader.download(
        job: _job('abc'),
        generationCheck: () => generationValid,
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );

      expect(outcome.kind, DownloadOutcomeKind.cancelled);
      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      // DB row should NOT have been written.
      expect(row.filePath, isNull);
    },
  );

  test(
    'testHookBeforeRename fires before testHookBeforeDbWrite',
    () async {
      await _insertTrack(db, 'abc');
      final downloader = buildDownloader(
        MockClient((req) async => http.Response.bytes([7, 7], 200)),
      );

      final calls = <String>[];
      downloader.testHookBeforeRename = (uuidId) async {
        calls.add('rename:$uuidId');
      };
      downloader.testHookBeforeDbWrite = (uuidId) async {
        calls.add('db:$uuidId');
      };

      final outcome = await downloader.download(
        job: _job('abc'),
        generationCheck: () => true,
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );

      expect(outcome.kind, DownloadOutcomeKind.success);
      expect(calls, ['rename:abc', 'db:abc']);
    },
  );

  test(
    'generation flip between rename and DB write cleans up destination',
    () async {
      await _insertTrack(db, 'abc');
      final downloader = buildDownloader(
        MockClient((req) async => http.Response.bytes([7, 7], 200)),
      );

      // Allow generation to be true during HTTP + body + pre-rename, then
      // flip it false between rename and DB write.
      var generationValid = true;
      downloader.testHookBeforeDbWrite = (_) async {
        generationValid = false;
      };

      final outcome = await downloader.download(
        job: _job('abc'),
        generationCheck: () => generationValid,
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );

      expect(outcome.kind, DownloadOutcomeKind.cancelled);
      final row = await (db.select(
        db.tracks,
      )..where((t) => t.uuidId.equals('abc'))).getSingle();
      // DB row should NOT have been written.
      expect(row.filePath, isNull);
      // The destination file should not have been left behind.
      final destFiles = Directory('${tempDir.path}/tracks').existsSync()
          ? Directory('${tempDir.path}/tracks').listSync()
          : const <FileSystemEntity>[];
      expect(
        destFiles.where(
          (f) => f.path.contains('abc') && !f.path.endsWith('.partial'),
        ),
        isEmpty,
      );
    },
  );

  test('non-2xx HTTP becomes otherFailure', () async {
    final downloader = buildDownloader(
      MockClient((req) async => http.Response('not found', 404)),
    );

    final outcome = await downloader.download(
      job: _job('abc'),
      generationCheck: () => true,
      onProgress: (_) {},
      registerCanceller: (_) {},
      unregisterCanceller: () {},
    );
    expect(outcome.kind, DownloadOutcomeKind.otherFailure);
    expect(outcome.errorMessage, contains('404'));
  });
}
