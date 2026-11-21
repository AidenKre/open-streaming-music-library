// Section 6 #8 (owner, 2026-11-17): when downloads are deleted, a stored
// cover is deleted from the device if no remaining download uses it. The
// check runs after the download rows are cleared; a cover a downloaded
// track (or a kept damaged copy) still refers to is never removed.
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore store;
  late DownloadManager manager;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('download-cover-cleanup');
    final api = testApiClient(
      'http://test:8080',
      MockClient((_) async => http.Response('', 404)),
    );
    store = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
      apiClient: api,
    );
    manager = DownloadManager(
      db: db,
      coverArtStore: store,
      directoryProvider: () async => tempDir,
      apiClient: api,
    );
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
    await tempDir.delete(recursive: true);
  });

  /// A track with cover [cover]; downloaded (a file in the downloads
  /// folder) unless [downloaded] is false; a download kept as damaged when
  /// [damaged] (the mark names the recorded file, as the app writes it).
  Future<void> track(
    String uuid,
    int cover, {
    bool downloaded = true,
    bool damaged = false,
  }) async {
    String? path;
    if (downloaded) {
      final file = File(p.join(tempDir.path, 'tracks', '$uuid.m4a'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      path = file.path;
    }
    await db.into(db.tracks).insert(TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          filePath: Value(path),
          damagedFilePath: Value(damaged ? path : null),
          downloadedQuality: Value(path == null ? null : '320'),
        ));
    await db.into(db.trackmetadata).insert(TrackmetadataCompanion.insert(
          uuidId: uuid,
          duration: const Value(120),
          bitrateKbps: const Value(320),
          sampleRateHz: const Value(44100),
          channels: const Value(2),
          hasAlbumArt: const Value(true),
          coverArtId: Value(cover),
        ));
  }

  void storeCover(int id) => store.fileFor(id).writeAsBytesSync([9]);

  test('a cover shared by two downloads stays until the last of them is '
      'deleted', () async {
    await track('a', 7);
    await track('b', 7);
    storeCover(7);

    await manager.deleteDownload('a');
    expect(store.has(7), isTrue, reason: 'b still uses it');

    await manager.deleteDownload('b');
    expect(store.has(7), isFalse);
  });

  test('a track that only streams does not keep a cover', () async {
    await track('a', 7);
    await track('s', 7, downloaded: false);
    storeCover(7);

    await manager.deleteDownloadsForUuids(['a']);

    expect(store.has(7), isFalse);
  });

  test("a kept damaged copy keeps its track's cover", () async {
    await track('a', 8);
    await track('d', 8, damaged: true);
    storeCover(8);

    await manager.deleteDownload('a');

    expect(store.has(8), isTrue);
  });

  test('only the deleted downloads\' covers are looked at', () async {
    await track('a', 7);
    await track('b', 9);
    await track('c', 9);
    storeCover(7);
    storeCover(9);
    storeCover(11); // no track names it

    await manager.deleteDownloadsForUuids(['a', 'b']);

    expect(store.has(7), isFalse);
    expect(store.has(9), isTrue, reason: 'c still uses it');
    expect(store.has(11), isTrue, reason: 'not a deleted download\'s cover');
  });

  test('a track that was not downloaded removes no cover', () async {
    await track('s', 7, downloaded: false);
    storeCover(7);

    await manager.deleteDownload('s');

    expect(store.has(7), isTrue);
  });
}
