import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/local_cover_art_store.dart';

Future<void> _insertTrack(
  AppDatabase db,
  String uuid, {
  int? revision,
  String? codec,
}) async {
  await db
      .into(db.tracks)
      .insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          revision: Value(revision),
        ),
      );
  await db
      .into(db.trackmetadata)
      .insert(
        TrackmetadataCompanion.insert(
          uuidId: uuid,
          codec: Value(codec),
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

Future<Track> _row(AppDatabase db, String uuid) =>
    (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid))).getSingle();

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

  Future<DownloadOutcome> run(TrackDownloader d, DownloadJob job) =>
      d.download(
        job: job,
        generationCheck: () => true,
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );

  group('downloadedAtRevision', () {
    test('uses X-Track-Revision when the server sends it', () async {
      await _insertTrack(db, 'abc', revision: 7, codec: 'flac');
      // The server is ahead of the local sync (rev 9): the bytes are current
      // as of 9, so a later /changes catching the local row up to 9 must not
      // flag them.
      final downloader = buildDownloader(
        MockClient(
          (req) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'x-track-revision': '9'},
          ),
        ),
      );

      await run(downloader, _job('abc', quality: 'original'));

      expect((await _row(db, 'abc')).downloadedAtRevision, 9);
    });

    test(
      'without the header, falls back to the local revision read before '
      'the request',
      () async {
        await _insertTrack(db, 'abc', revision: 7, codec: 'flac');
        final downloader = buildDownloader(
          MockClient((req) async => http.Response.bytes([1, 2, 3], 200)),
        );

        await run(downloader, _job('abc', quality: 'original'));

        expect((await _row(db, 'abc')).downloadedAtRevision, 7);
      },
    );

    test(
      'a revision bump landing mid-download (old server, no header) leaves '
      'the download stale rather than recording it as fresh',
      () async {
        await _insertTrack(db, 'abc', revision: 7, codec: 'flac');
        final downloader = buildDownloader(
          MockClient((req) async => http.Response.bytes([1, 2, 3], 200)),
        );
        // A conversion lands and /changes raises the local revision after
        // the old-master bytes were already streamed.
        downloader.testHookBeforeRename = (_) async {
          await db.updateTrackRevision('abc', 8);
        };

        await run(downloader, _job('abc', quality: 'original'));

        final row = await _row(db, 'abc');
        expect(row.revision, 8);
        expect(row.downloadedAtRevision, 7);
        final track = TrackUI.fromQueryRow(
          (await db.getTrackByUuid('abc')).single,
        );
        expect(track.isStaleDownload, isTrue);
      },
    );

    test('unknown revision (no header, null local) stores 0', () async {
      await _insertTrack(db, 'abc', codec: 'flac');
      final downloader = buildDownloader(
        MockClient((req) async => http.Response.bytes([1, 2, 3], 200)),
      );

      await run(downloader, _job('abc', quality: 'original'));

      expect((await _row(db, 'abc')).downloadedAtRevision, 0);
      // Any revision the track is later seen at flags it.
      await db.updateTrackRevision('abc', 1);
      final track = TrackUI.fromQueryRow(
        (await db.getTrackByUuid('abc')).single,
      );
      expect(track.isStaleDownload, isTrue);
    });

    test('a malformed header falls back like an absent one', () async {
      await _insertTrack(db, 'abc', revision: 4, codec: 'flac');
      final downloader = buildDownloader(
        MockClient(
          (req) async => http.Response.bytes(
            [1],
            200,
            headers: {'x-track-revision': 'nope'},
          ),
        ),
      );

      await run(downloader, _job('abc', quality: 'original'));

      expect((await _row(db, 'abc')).downloadedAtRevision, 4);
    });
  });

  group('downloadedCodec', () {
    test('uses X-Audio-Codec when the server sends it', () async {
      await _insertTrack(db, 'abc', revision: 1, codec: 'flac');
      final downloader = buildDownloader(
        MockClient(
          (req) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'x-audio-codec': 'aac', 'content-type': 'audio/mp4'},
          ),
        ),
      );

      await run(downloader, _job('abc', quality: '192'));

      expect((await _row(db, 'abc')).downloadedCodec, 'aac');
    });

    test(
      'a passthrough at a non-original preset keeps the source codec '
      '(mp3 requested at 320 -> mp3)',
      () async {
        await _insertTrack(db, 'abc', revision: 1, codec: 'mp3');
        final downloader = buildDownloader(
          MockClient(
            (req) async => http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {
                'x-audio-codec': 'mp3',
                'content-type': 'audio/mpeg',
                'x-audio-bitrate-kbps': '256',
              },
            ),
          ),
        );

        await run(downloader, _job('abc', quality: '320'));

        expect((await _row(db, 'abc')).downloadedCodec, 'mp3');
      },
    );

    test(
      'fallback (no header): original quality uses the codec read at '
      'attempt time, not enqueue time',
      () async {
        await _insertTrack(db, 'abc', revision: 1, codec: 'mp3');
        // Converted between enqueue and the attempt: the local row already
        // carries the new master's codec when the download starts.
        await (db.update(db.trackmetadata)
              ..where((t) => t.uuidId.equals('abc')))
            .write(const TrackmetadataCompanion(codec: Value('flac')));
        final downloader = buildDownloader(
          MockClient(
            (req) async => http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'audio/flac'},
            ),
          ),
        );

        await run(downloader, _job('abc', quality: 'original'));

        expect((await _row(db, 'abc')).downloadedCodec, 'flac');
      },
    );

    test(
      'fallback (no header): audio/mp4 from a non-mp4 source means aac',
      () async {
        await _insertTrack(db, 'abc', revision: 1, codec: 'flac');
        final downloader = buildDownloader(
          MockClient(
            (req) async => http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'audio/mp4'},
            ),
          ),
        );

        await run(downloader, _job('abc', quality: '192'));

        expect((await _row(db, 'abc')).downloadedCodec, 'aac');
      },
    );

    test(
      'fallback (no header): a non-mp4 content type is a passthrough of '
      'the source codec',
      () async {
        await _insertTrack(db, 'abc', revision: 1, codec: 'mp3');
        final downloader = buildDownloader(
          MockClient(
            (req) async => http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'audio/mpeg'},
            ),
          ),
        );

        await run(downloader, _job('abc', quality: '192'));

        expect((await _row(db, 'abc')).downloadedCodec, 'mp3');
      },
    );

    test(
      'a failing pre-request track-state read fails the job instead of '
      'throwing (which would leave it stuck active)',
      () async {
        await _insertTrack(db, 'abc');
        var requests = 0;
        final downloader = buildDownloader(
          MockClient((req) async {
            requests++;
            return http.Response.bytes([1, 2, 3], 200);
          }),
        );
        // Break the pre-request SELECT (it joins trackmetadata).
        await db.customStatement('DROP TABLE trackmetadata');

        final outcome = await run(downloader, _job('abc'));

        expect(outcome.kind, DownloadOutcomeKind.otherFailure);
        expect(requests, 0, reason: 'bailed before sending the request');
      },
    );

    test('resolveDownloadedCodec fallback table', () {
      String? resolve({
        String? header,
        String quality = '192',
        String? source,
        String? contentType,
      }) => TrackDownloader.resolveDownloadedCodec(
        headerCodec: header,
        quality: quality,
        sourceCodec: source,
        contentType: contentType,
      );

      expect(resolve(header: ' FLAC ', source: 'mp3'), 'flac');
      expect(resolve(header: '', source: 'mp3', contentType: 'audio/mpeg'),
          'mp3');
      expect(resolve(quality: 'original', source: 'alac',
          contentType: 'audio/mp4'), 'alac');
      expect(resolve(source: 'flac', contentType: 'audio/mp4; foo=bar'),
          'aac');
      expect(resolve(source: 'aac', contentType: 'audio/mp4'), 'aac');
      // An ALAC source at a preset is transcoded to AAC (lossless is never
      // under a preset bitrate), served as audio/mp4 like any AAC.
      expect(resolve(source: 'alac', contentType: 'audio/mp4'), 'aac');
      expect(resolve(source: 'flac', contentType: 'audio/flac'), 'flac');
      expect(resolve(source: 'flac'), 'flac');
    });
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

  test('testHookBeforeRename fires before testHookBeforeDbWrite', () async {
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
  });

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

  test('deleted track row during commit cleans up destination', () async {
    await _insertTrack(db, 'abc');
    final downloader = buildDownloader(
      MockClient((req) async => http.Response.bytes([7, 7], 200)),
    );

    downloader.testHookBeforeDbWrite = (_) async {
      await (db.delete(
        db.trackmetadata,
      )..where((t) => t.uuidId.equals('abc'))).go();
      await (db.delete(db.tracks)..where((t) => t.uuidId.equals('abc'))).go();
    };

    final outcome = await downloader.download(
      job: _job('abc'),
      generationCheck: () => true,
      onProgress: (_) {},
      registerCanceller: (_) {},
      unregisterCanceller: () {},
    );

    expect(outcome.kind, DownloadOutcomeKind.cancelled);
    expect(await db.select(db.tracks).get(), isEmpty);
    final tracksDir = Directory('${tempDir.path}/tracks');
    final destFiles = tracksDir.existsSync()
        ? tracksDir.listSync().where((f) => !f.path.endsWith('.partial'))
        : const <FileSystemEntity>[];
    expect(destFiles, isEmpty);
  });

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
