// Phase 5 decision 6: DownloadsController's damaged-download input.
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/downloads_controller.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late DownloadManager manager;
  late ProviderContainer c;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('dl-controller-damaged');
    manager = DownloadManager(
      db: db,
      coverArtStore: await LocalCoverArtStore.create(
          directoryProvider: () async => tempDir),
      directoryProvider: () async => tempDir,
      isOfflineFn: () => true, // jobs stay queued, observable
    );
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      downloadManagerProvider.overrideWithValue(manager),
      downloadQualityProvider.overrideWithValue('256'),
    ]);
    await db.into(db.tracks).insert(TracksCompanion.insert(
        uuidId: 'a', createdAt: 0, lastUpdated: 0));
  });

  tearDown(() async {
    c.dispose();
    manager.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // A pre-2026-11-09 mark moved the path off file_path ([legacy]); a mark
  // now keeps the download and its quality.
  TrackUI damagedTrack(String path,
          {bool legacy = false, String? downloadedQuality}) =>
      TrackUI(
        uuidId: 'a',
        createdAt: 0,
        lastUpdated: 0,
        duration: 1,
        bitrateKbps: null,
        sampleRateHz: null,
        channels: null,
        hasAlbumArt: false,
        filePath: legacy ? null : path,
        downloadedQuality: downloadedQuality,
        damagedFilePath: path,
      );

  test('redownloadDamaged queues a download at the default quality when '
      'the original is unknown', () async {
    await c
        .read(downloadsControlsProvider)
        .redownloadDamaged([damagedTrack('/dl/a', legacy: true)]);
    final jobs = manager.snapshot();
    expect(jobs.map((j) => (j.uuidId, j.quality, j.isQueued)),
        [('a', '256', true)]);
  });

  test('redownloadDamaged re-downloads at the original quality and replaces '
      'the kept file only once the new one is in', () async {
    final file = File('${tempDir.path}/a.bad')..writeAsBytesSync([9]);
    await c.read(downloadsControlsProvider).redownloadDamaged(
        [damagedTrack(file.path, downloadedQuality: 'original')]);
    final jobs = manager.snapshot();
    expect(
        jobs.map((j) => (j.uuidId, j.quality, j.isQueued, j.replacesFilePath)),
        [('a', 'original', true, file.path)]);
  });

  test('a plain Download of a damaged track replaces it (it is not "already '
      'downloaded"), at the quality it was downloaded at', () async {
    final file = File('${tempDir.path}/a.bad')..writeAsBytesSync([9]);
    await manager.enqueueTracks(
        [damagedTrack(file.path, downloadedQuality: 'original')],
        quality: '256');
    expect(
        manager.snapshot().map((j) => (j.uuidId, j.replacesFilePath, j.quality)),
        [('a', file.path, 'original')]);
  });

  test('an explicit "Download at" quality wins over the stored one', () async {
    final file = File('${tempDir.path}/a.bad')..writeAsBytesSync([9]);
    await manager.enqueueTracksAtQuality(
        [damagedTrack(file.path, downloadedQuality: 'original')],
        quality: '128');
    expect(manager.snapshot().map((j) => j.quality), ['128']);
  });

  test('deleteDamaged removes the kept file and the mark', () async {
    final file = File('${tempDir.path}/a.bad')..writeAsBytesSync([9]);
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
        .write(TracksCompanion(damagedFilePath: Value(file.path)));
    await c.read(downloadsControlsProvider).deleteDamaged('a');
    expect(file.existsSync(), isFalse);
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('a')))
        .getSingle();
    expect(row.damagedFilePath, isNull);
  });
}
