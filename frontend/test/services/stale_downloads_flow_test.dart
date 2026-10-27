import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/sync_service.dart';

/// End-to-end-ish: a real `/changes` sync, a real download pipeline and the
/// SQL stale query the banner watches, wired against one mock server.
void main() {
  late AppDatabase db;
  late Directory tempDir;
  late DownloadManager manager;
  late SyncService sync;
  late BrowseRepository browse;

  // Tiny server model: one track whose revision/codec the test mutates.
  var serverRevision = 0;
  var serverCodec = 'flac';
  final changes = <Map<String, dynamic>>[];

  Map<String, dynamic> trackJson() => {
    'uuid_id': 'u1',
    'created_at': 0,
    'last_updated': 0,
    'revision': serverRevision,
    'metadata': {
      'title': 'Song',
      'artist': 'A',
      'codec': serverCodec,
      'duration': 1.0,
      'bitrate_kbps': 900.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  };

  /// A server-side change to the track (conversion, edit elsewhere, art).
  void serverChange({String? codec}) {
    serverRevision += 1;
    if (codec != null) serverCodec = codec;
    changes.add({
      'type': 'upsert',
      'revision': serverRevision,
      'uuid_id': 'u1',
      'track': trackJson(),
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    serverRevision = 0;
    serverCodec = 'flac';
    changes.clear();
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('stale-flow-test');
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((req) async {
        final segs = req.url.pathSegments;
        if (segs.isNotEmpty && segs.first == 'changes') {
          final after =
              int.parse(req.url.queryParameters['after_revision'] ?? '0');
          return http.Response(
            jsonEncode({
              'changes': [
                for (final c in changes)
                  if ((c['revision'] as int) > after) c,
              ],
              'latestRevision': serverRevision,
              'nextCursor': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (segs.length == 3 && segs.last == 'stream') {
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {
              'x-audio-extension': serverCodec,
              'x-audio-codec': serverCodec,
              'x-audio-bitrate-kbps': '900',
              'x-track-revision': '$serverRevision',
            },
          );
        }
        return http.Response('not found', 404);
      }),
    );
    final coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
    manager = DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
    );
    sync = SyncService(
      db: db,
      api: TracksApi(),
      queueRepository: QueueRepository(db),
      prefs: await SharedPreferences.getInstance(),
    );
    browse = BrowseRepository(db);
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> waitForDownloads() async {
    while (manager.snapshot().any((j) => j.isActive || j.isQueued)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<List<String>> stale() async =>
      [for (final t in await browse.watchStaleDownloads().first) t.uuidId];

  Future<void> downloadU1({bool force = false}) async {
    final track = (await browse.getTrack('u1'))!;
    if (force) {
      await manager.enqueueTracksAtQuality(
        [track],
        quality: track.downloadedQuality!,
        force: true,
      );
    } else {
      await manager.enqueueTracks([track], quality: 'original');
    }
    await waitForDownloads();
  }

  test('stale -> re-download completes -> stale list clears', () async {
    serverChange();
    await sync.syncChanges();
    await downloadU1();
    expect(await stale(), isEmpty);

    // A conversion lands server-side and the next sync pulls it.
    serverChange(codec: 'alac');
    await sync.syncChanges();
    expect(await stale(), ['u1']);
    final staleTrack = (await browse.getTrack('u1'))!;
    expect(staleTrack.downloadedCodec, 'flac');
    expect(staleTrack.codec, 'alac');
    final oldPath = staleTrack.filePath!;

    await downloadU1(force: true);

    expect(await stale(), isEmpty);
    final fresh = (await browse.getTrack('u1'))!;
    expect(fresh.downloadedCodec, 'alac');
    expect(fresh.downloadedAtRevision, serverRevision);
    expect(File(oldPath).existsSync(), isFalse);
    expect(File(fresh.filePath!).existsSync(), isTrue);
  });

  test('dismiss -> revision climbs again via a sync upsert -> reappears',
      () async {
    serverChange();
    await sync.syncChanges();
    await downloadU1();

    serverChange(); // e.g. artwork changed elsewhere
    await sync.syncChanges();
    expect(await stale(), ['u1']);

    await db.dismissStaleDownload('u1');
    expect(await stale(), isEmpty);

    // A sync that re-delivers nothing new keeps it dismissed...
    await sync.syncChanges();
    expect(await stale(), isEmpty);

    // ...but a second server-side change re-arms the warning.
    serverChange(codec: 'aac');
    await sync.syncChanges();
    expect(await stale(), ['u1']);
  });
}
