import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart'
    show QueryRow, ResultSetImplementation, Selectable, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/api/token_permit.dart';

import '../../helpers/server_binding.dart';

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
          duration: const Value(120),
          bitrateKbps: const Value(320),
          sampleRateHz: const Value(44100),
          channels: const Value(2),
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

/// A transport whose delegate each test swaps after the shared client exists.
class _SwapClient extends http.BaseClient {
  http.Client inner = MockClient((_) async => http.Response.bytes([1], 200));
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
}

/// The real database. When the sweep reads the track rows it starts a
/// rebind: a reset and a new sign-in landing while the sweep runs (the
/// statements run in the order they are issued).
class _RebindDuringSweepDb extends AppDatabase {
  _RebindDuringSweepDb() : super(NativeDatabase.memory());

  bool armed = false;

  @override
  Selectable<QueryRow> customSelect(
    String query, {
    List<Variable> variables = const [],
    Set<ResultSetImplementation> readsFrom = const {},
  }) {
    if (armed &&
        query.startsWith('SELECT file_path, damaged_file_path FROM tracks')) {
      armed = false;
      unawaited(customStatement(
          "UPDATE server_binding SET local_binding_id = 'new-session'"));
    }
    return super.customSelect(query, variables: variables, readsFrom: readsFrom);
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;
  late _SwapClient transport;
  late ApiClient api;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('track_downloader_test_');
    transport = _SwapClient();
    api = testApiClient('http://test:8080', transport);
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
      apiClient: api,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  TrackDownloader buildDownloader(http.Client client) {
    transport.inner = client;
    return TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: api,
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

  // Review major 1: a truncated body is never committed (it would only fail
  // at playback and look damaged).
  test('a body shorter than Content-Length fails and commits nothing',
      () async {
    await _insertTrack(db, 'abc');
    final downloader = buildDownloader(MockClient.streaming((req, _) async =>
        http.StreamedResponse(Stream.value([1, 2]), 200, contentLength: 5)));
    final outcome = await downloader.download(
      job: _job('abc'),
      generationCheck: () => true,
      onProgress: (_) {},
      registerCanceller: (_) {},
      unregisterCanceller: () {},
    );
    expect(outcome.kind, DownloadOutcomeKind.otherFailure);
    expect(outcome.errorMessage, contains('2 of 5 bytes'));
    expect((await _row(db, 'abc')).filePath, isNull);
    expect(tempDir.listSync(recursive: true).whereType<File>()
        .where((f) => f.path.contains('abc')), isEmpty,
        reason: 'the partial file is removed');
  });

  test('a body of unknown length is accepted', () async {
    await _insertTrack(db, 'abc');
    final downloader = buildDownloader(MockClient.streaming((req, _) async =>
        http.StreamedResponse(Stream.value([1, 2]), 200)));
    final outcome = await downloader.download(
      job: _job('abc'),
      generationCheck: () => true,
      onProgress: (_) {},
      registerCanceller: (_) {},
      unregisterCanceller: () {},
    );
    expect(outcome.kind, DownloadOutcomeKind.success);
  });

  // Decision 6: a new download of a damaged track replaces the damaged file.
  group('a damaged download', () {
    test('a new download clears the mark and removes the damaged file',
        () async {
      await _insertTrack(db, 'abc');
      final damaged = File('${tempDir.path}/tracks/abc.bad.m4a');
      await damaged.parent.create(recursive: true);
      await damaged.writeAsBytes([9]);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('abc')))
          .write(TracksCompanion(damagedFilePath: Value(damaged.path)));
      final outcome = await run(
          buildDownloader(
              MockClient((_) async => http.Response.bytes([1, 2], 200))),
          _job('abc'));
      expect(outcome.kind, DownloadOutcomeKind.success);
      final row = await _row(db, 'abc');
      expect(row.damagedFilePath, isNull);
      expect(File(row.filePath!).existsSync(), isTrue);
      expect(damaged.existsSync(), isFalse);
    });

    test('review: a fence right after the commit write still removes the '
        'damaged copy', () async {
      await _insertTrack(db, 'abc');
      // A clean run counts the generation checks; the last one follows the
      // DB write.
      var checks = 0;
      await buildDownloader(
              MockClient((_) async => http.Response.bytes([1], 200)))
          .download(
        job: _job('abc'),
        generationCheck: () => ++checks > 0,
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );
      final damaged = File('${tempDir.path}/tracks/abc.old.flac');
      await damaged.parent.create(recursive: true);
      await damaged.writeAsBytes([9]);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('abc')))
          .write(clearedDownloadColumns.copyWith(
              damagedFilePath: Value(damaged.path)));
      var n = 0;
      final outcome = await buildDownloader(
              MockClient((_) async => http.Response.bytes([1, 2], 200)))
          .download(
        job: _job('abc'),
        generationCheck: () => ++n < checks, // fenced after the write
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );
      expect(outcome.kind, DownloadOutcomeKind.cancelled);
      final row = await _row(db, 'abc');
      expect((row.filePath, row.damagedFilePath), (null, null));
      expect(damaged.existsSync(), isFalse, reason: 'no orphan left behind');
    });

    test('a damaged file at the destination path is simply replaced',
        () async {
      await _insertTrack(db, 'abc');
      final first = await run(
          buildDownloader(MockClient((_) async => http.Response.bytes([1], 200))),
          _job('abc'));
      expect(first.kind, DownloadOutcomeKind.success);
      final path = (await _row(db, 'abc')).filePath!;
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('abc')))
          .write(clearedDownloadColumns.copyWith(damagedFilePath: Value(path)));
      await run(
          buildDownloader(
              MockClient((_) async => http.Response.bytes([1, 2, 3], 200))),
          _job('abc'));
      final row = await _row(db, 'abc');
      expect((row.filePath, row.damagedFilePath), (path, null));
      expect(File(path).lengthSync(), 3, reason: 'the new bytes, kept');
    });
  });

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

  // U24-FE-DL-B-03: the downloads folder could not be created (disk full,
  // no permission). The error escaped download(), so the worker pool never
  // recorded an outcome and the job stayed active for good.
  test('a downloads folder that cannot be created is an otherFailure',
      () async {
    await _insertTrack(db, 'abc');
    transport.inner = MockClient((_) async => http.Response.bytes([1], 200));
    final downloader = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async =>
          throw const FileSystemException('Creation failed', '/no/such'),
      apiClient: api,
    );

    final outcome = await run(downloader, _job('abc'));

    expect(outcome.kind, DownloadOutcomeKind.otherFailure);
    expect((await _row(db, 'abc')).filePath, isNull);
  });

  // U24-FE-DL-A-03: a crash or a failure between writing a download and
  // recording it leaves files no track row lists. The downloader sweeps them
  // once, before its first job writes: only its own temporary names, directly
  // in <documents>/tracks, never a file a track row names, never through a
  // link.
  group('the leftover sweep at the downloader\'s start', () {
    const u1 = '11111111-1111-4111-8111-111111111111';
    const u2 = '22222222-2222-4222-8222-222222222222';
    const u3 = '33333333-3333-4333-8333-333333333333';
    const job1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const job2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    late Directory tracks;

    setUp(() async {
      tracks = Directory(p.join(tempDir.path, 'tracks'));
      await tracks.create();
    });

    Future<File> put(String name, {Directory? into}) async {
      final f = File(p.join((into ?? tracks).path, name));
      await f.writeAsBytes([1]);
      return f;
    }

    http.Response audio() => http.Response.bytes([1, 2], 200,
        headers: {'x-audio-extension': 'm4a'});

    Future<void> firstDownload() async {
      await _insertTrack(db, job1);
      final outcome = await run(
          buildDownloader(MockClient((_) async => audio())), _job(job1));
      expect(outcome.kind, DownloadOutcomeKind.success);
    }

    test('removes the downloader\'s own temporary files', () async {
      final leftovers = [
        await put('$u1.m4a.partial'),
        await put('$u2.new-1700000000000000.flac.partial'),
        await put('$u3.new-1700000000000000.m4a'),
      ];
      await firstDownload();
      for (final f in leftovers) {
        expect(f.existsSync(), isFalse, reason: p.basename(f.path));
      }
    });

    test('keeps finished downloads and every name it does not create',
        () async {
      final kept = [
        await put('$u1.m4a'),
        await put('notes.txt'),
        await put('x$u1.m4a.partial'),
        await put('$u1.m4a.partial.keep'),
        await put('$u1.new-12.m4a.bak'),
        await put('x$u1.new-12.m4a'),
        // Wider than the names the downloader writes.
        await put('$u1.m4a.PARTIAL'),
        await put('$u1.NEW-12.m4a'),
        await put('$u1.new-.m4a'),
        await put('not-a-uuid.m4a.partial'),
      ];
      await firstDownload();
      for (final f in kept) {
        expect(f.existsSync(), isTrue, reason: p.basename(f.path));
      }
    });

    test('keeps a file a track row names', () async {
      final named = await put('$u1.new-5.m4a');
      final damaged = await put('$u2.new-6.m4a');
      await _insertTrack(db, u1);
      await _insertTrack(db, u2);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(u1)))
          .write(TracksCompanion(filePath: Value(named.path)));
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(u2)))
          .write(TracksCompanion(damagedFilePath: Value(damaged.path)));
      await firstDownload();
      expect(named.existsSync(), isTrue, reason: 'a row\'s file_path');
      expect(damaged.existsSync(), isTrue,
          reason: 'a row\'s damaged_file_path');
    });

    test('keeps a file whose name a track row gives in another folder',
        () async {
      // The documents folder can move (a new app container); a row may
      // still give the old absolute path of this very file.
      final named = await put('$u1.new-5.m4a');
      await _insertTrack(db, u1);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(u1))).write(
          TracksCompanion(
              filePath: Value('/old/container/tracks/$u1.new-5.m4a')));
      await firstDownload();
      expect(named.existsSync(), isTrue);
    });

    test('looks only directly inside the downloads folder', () async {
      final outside = await put('$u1.m4a.partial', into: tempDir);
      final sub = Directory(p.join(tracks.path, 'sub'));
      await sub.create();
      final nested = await put('$u2.m4a.partial', into: sub);
      await firstDownload();
      expect(outside.existsSync(), isTrue, reason: 'outside the folder');
      expect(nested.existsSync(), isTrue, reason: 'in a subfolder');
    });

    test('leaves a link with a temporary name alone', () async {
      final elsewhere = await Directory.systemTemp.createTemp('sweep_target_');
      addTearDown(() => elsewhere.delete(recursive: true));
      final victim = File(p.join(elsewhere.path, 'victim'));
      await victim.writeAsBytes([1]);
      final link = Link(p.join(tracks.path, '$u1.m4a.partial'));
      await link.create(victim.path);
      await firstDownload();
      expect(victim.existsSync(), isTrue);
      expect(link.existsSync(), isTrue, reason: 'links are never removed');
    });

    test('sweeps nothing when the downloads folder is a link', () async {
      await tracks.delete();
      final elsewhere = await Directory.systemTemp.createTemp('sweep_target_');
      addTearDown(() => elsewhere.delete(recursive: true));
      final victim = File(p.join(elsewhere.path, '$u1.m4a.partial'));
      await victim.writeAsBytes([1]);
      await Link(tracks.path).create(elsewhere.path);
      await firstDownload();
      expect(victim.existsSync(), isTrue);
    });

    test('sweeps nothing when the track rows cannot be read', () async {
      final leftover = await put('$u1.m4a.partial');
      await db.customStatement('ALTER TABLE tracks RENAME TO tracks_moved');
      await run(buildDownloader(MockClient((_) async => audio())), _job(job1));
      expect(leftover.existsSync(), isTrue);
    });

    // Phase 8 (review #2 of the Phase 7 part): the sweep only finds; the
    // owned-file clean-up decides each unlink (DEV-8-08). A leftover of an
    // abandoned worker that a new session's download replaced under the same
    // name between the find and the attempt is retired, not deleted.
    test('a leftover replaced under its name before the attempt is kept',
        () async {
      final leftover = await put('$u1.m4a.partial');
      // Hold the file's path lock, as a writer of that path would.
      final release = Completer<void>();
      final held = sharedOwnedPathLocks.withLock(
          leftover.path, () => release.future);
      await _insertTrack(db, job1);
      final download = run(
          buildDownloader(MockClient((_) async => audio())), _job(job1));

      var enqueued = false;
      for (var i = 0; i < 1000 && !enqueued; i++) {
        await Future<void>.delayed(Duration.zero);
        enqueued =
            (await db.select(db.ownedFileCleanupEntries).get()).isNotEmpty;
      }
      expect(enqueued, isTrue,
          reason: 'the sweep did not go through the owned-file clean-up');
      // The new session's download writes the same name meanwhile.
      await leftover.writeAsBytes([7, 7, 7, 7]);
      release.complete();
      await held;

      expect((await download).kind, DownloadOutcomeKind.success);
      expect(leftover.existsSync(), isTrue,
          reason: 'a file whose identity changed was deleted');
      expect(await db.select(db.ownedFileCleanupEntries).get(), isEmpty,
          reason: 'the row is retired, not kept for a retry');
    });

    // Cascade-8 review #3: a sweep whose session ends while it runs (a
    // reset and a new sign-in) must not hand its finds to the new session's
    // clean-up: the binding is read when the sweep starts and fences it.
    test('a sweep whose session changes while it runs removes nothing',
        () async {
      final rebinding = _RebindDuringSweepDb();
      addTearDown(rebinding.close);
      await seedTestBinding(rebinding);
      final leftover = await put('$u1.m4a.partial');
      rebinding.armed = true;
      transport.inner = MockClient((_) async => audio());
      final downloader = TrackDownloader(
        db: rebinding,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        apiClient: api,
      );

      await run(downloader, _job(job1));

      expect(rebinding.armed, isFalse, reason: 'the sweep read the rows');
      expect(leftover.existsSync(), isTrue,
          reason: 'the old session\'s sweep cleaned for the new one');
      expect(await rebinding.select(rebinding.ownedFileCleanupEntries).get(),
          isEmpty);
    });

    test('runs once: a job\'s own temporary file survives later jobs',
        () async {
      await _insertTrack(db, job1);
      await _insertTrack(db, job2);
      final body = StreamController<List<int>>();
      final downloader = buildDownloader(MockClient.streaming((req, _) async {
        if (req.url.path.contains(job1)) {
          return http.StreamedResponse(body.stream, 200,
              contentLength: 2, headers: {'x-audio-extension': 'm4a'});
        }
        return http.StreamedResponse(Stream.value([3]), 200,
            contentLength: 1, headers: {'x-audio-extension': 'm4a'});
      }));
      final first = run(downloader, _job(job1));
      body.add([1]);
      final partial = File(p.join(tracks.path, '$job1.m4a.partial'));
      for (var i = 0; i < 1000 && !partial.existsSync(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(partial.existsSync(), isTrue, reason: 'first job is writing');

      final second = await run(downloader, _job(job2));
      expect(second.kind, DownloadOutcomeKind.success);

      body.add([2]);
      await body.close();
      expect((await first).kind, DownloadOutcomeKind.success);
    });
  });

  // U24-FE-DL-A-03, second half: the record step failed after the rename.
  group('a record step that throws', () {
    Future<void> failRecordWrites() => db.customStatement(
        'CREATE TRIGGER fail_record BEFORE UPDATE ON tracks '
        "BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END");

    test('removes the renamed file', () async {
      await _insertTrack(db, 'abc');
      final downloader = buildDownloader(MockClient((_) async =>
          http.Response.bytes([1, 2], 200,
              headers: {'x-audio-extension': 'm4a'})));
      downloader.testHookBeforeDbWrite = (_) => failRecordWrites();

      final outcome = await run(downloader, _job('abc'));

      expect(outcome.kind, DownloadOutcomeKind.otherFailure);
      expect((await _row(db, 'abc')).filePath, isNull);
      expect(Directory(p.join(tempDir.path, 'tracks')).listSync(), isEmpty,
          reason: 'a file no row lists is left behind');
    });

    test('keeps the file when a track row names its path', () async {
      await _insertTrack(db, 'abc');
      final tracks = Directory(p.join(tempDir.path, 'tracks'));
      await tracks.create();
      // A kept damaged copy (decision 6) sits at the destination's name.
      final dest = File(p.join(tracks.path, 'abc.m4a'));
      await dest.writeAsBytes([9]);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('abc')))
          .write(TracksCompanion(damagedFilePath: Value(dest.path)));
      final downloader = buildDownloader(MockClient((_) async =>
          http.Response.bytes([1, 2], 200,
              headers: {'x-audio-extension': 'm4a'})));
      downloader.testHookBeforeDbWrite = (_) => failRecordWrites();

      final outcome = await run(downloader, _job('abc'));

      expect(outcome.kind, DownloadOutcomeKind.otherFailure);
      expect(dest.existsSync(), isTrue, reason: 'a row names this path');
    });
  });

  // Review #3: a reset (deleteDownloadDirectory) lands while the folder is
  // being prepared, and that stale preparation then fails. It must not drop
  // the newer preparation, or the next job would start a second sweep while
  // the second job is already writing.
  test('a stale failing preparation does not start a second sweep',
      () async {
    for (final u in ['j1', 'j2', 'j3']) {
      await _insertTrack(db, u);
    }
    transport.inner = MockClient((_) async => http.Response.bytes([1], 200,
        headers: {'x-audio-extension': 'm4a'}));
    var calls = 0;
    final gate1 = Completer<void>();
    final gate3 = Completer<void>();
    final downloader = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      apiClient: api,
      directoryProvider: () async {
        final n = ++calls;
        if (n == 1) {
          await gate1.future;
          throw const FileSystemException('Creation failed', '/gone');
        }
        if (n == 3) await gate3.future;
        return tempDir;
      },
    );

    final first = run(downloader, _job('j1')); // preparation 1 waits
    await pumpEventQueue();
    await downloader.deleteDownloadDirectory(); // the reset
    final second = run(downloader, _job('j2')); // preparation 2 waits
    await pumpEventQueue();
    gate1.complete(); // the stale preparation fails
    expect((await first).kind, DownloadOutcomeKind.otherFailure);
    final third = run(downloader, _job('j3')); // shares preparation 2
    await pumpEventQueue();
    gate3.complete();

    expect((await second).kind, DownloadOutcomeKind.success);
    expect((await third).kind, DownloadOutcomeKind.success);
    expect(calls, 3, reason: 'a second preparation (and sweep) started');
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

  // Phase M §7.2/§7.3, M-U20: the stream URI is built from the downloader's
  // own (scope-bound) client's base URL, never a process-wide one.
  test('requests the stream from its own client\'s base URL', () async {
    await _insertTrack(db, 'abc');
    final seen = <Uri>[];
    final downloader = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: testApiClient(
        'http://scope:9/base',
        MockClient((req) async {
          seen.add(req.url);
          return http.Response.bytes([1, 2, 3], 200);
        }),
      ),
    );

    final outcome = await run(downloader, _job('abc', quality: '256'));

    expect(outcome.kind, DownloadOutcomeKind.success);
    expect(
      seen.map((u) => u.toString()),
      ['http://scope:9/base/tracks/abc/stream?quality=256'],
    );
  });

  // Phase M §7.3 (M-U20): downloads authenticate with the header that the
  // scope's AuthenticatedClient adds; the media token never appears in the
  // download URI (only JustAudioEngine puts a token in a URL).
  test('downloads carry the bearer header and no token in the URL', () async {
    await _insertTrack(db, 'abc');
    final seen = <http.BaseRequest>[];
    final downloader = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: testApiClient(
        'http://scope:9',
        AuthenticatedClient(
          MockClient((req) async {
            seen.add(req);
            return http.Response.bytes([1, 2, 3], 200);
          }),
          const Credentials(
            token: 'api-token-A',
            mediaToken: 'media-token-A',
            userId: 7,
            username: 'alice',
          ),
          permit: const _AllowAllPermit(),
        ),
      ),
    );

    final outcome = await run(downloader, _job('abc', quality: '256'));

    expect(outcome.kind, DownloadOutcomeKind.success);
    expect(seen.single.headers['Authorization'], 'Bearer api-token-A');
    expect(
      seen.single.url.toString(),
      'http://scope:9/tracks/abc/stream?quality=256',
    );
  });
}

/// Fixture: the subject here is the download request, not the permit
/// (sign-off OPEN-M-11 has its own tests).
class _AllowAllPermit implements TokenPermit {
  const _AllowAllPermit();
  @override
  bool allowsTokenTo(Uri url) => true;
  @override
  Future<void> verdictSettled() async {}
}
