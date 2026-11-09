// Review major 1 (user, 2026-11-09): an "original" download of a codec this
// device can't decode is downloaded transcoded (AAC 320), and says so.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late DownloadManager manager;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('dl-codec');
    manager = DownloadManager(
      db: db,
      coverArtStore: await LocalCoverArtStore.create(
          directoryProvider: () async => tempDir),
      directoryProvider: () async => tempDir,
      isOfflineFn: () => true, // jobs stay queued, observable
      codecSupportFn: () => const CodecSupport({
        AudioCodecFamily.mp3,
        AudioCodecFamily.aac,
        AudioCodecFamily.flac,
        AudioCodecFamily.pcm,
      }),
    );
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  TrackUI track(String uuid, String? codec,
          {String? filePath, String? downloadedQuality}) =>
      TrackUI(
        uuidId: uuid,
        createdAt: 0,
        lastUpdated: 0,
        duration: 1,
        bitrateKbps: null,
        sampleRateHz: null,
        channels: null,
        hasAlbumArt: false,
        codec: codec,
        filePath: filePath,
        downloadedQuality: downloadedQuality,
      );

  test('original of an undecodable codec downloads at 320 and names it',
      () async {
    await manager.enqueueTracks(
        [track('alac', 'alac'), track('flac', 'flac'), track('unknown', null)],
        quality: 'original');
    expect(
        manager.snapshot().map((j) => (j.uuidId, j.quality, j.unsupportedCodec)),
        [
          ('alac', '320', 'ALAC'),
          ('flac', 'original', null),
          ('unknown', 'original', null),
        ]);
  });

  test('a chosen preset is left alone', () async {
    await manager.enqueueTracks([track('alac', 'alac')], quality: '128');
    expect(manager.snapshot().map((j) => (j.quality, j.unsupportedCodec)),
        [('128', null)]);
  });

  test('"Download at Original" of an undecodable track already at 320 is a '
      'no-op, not a loop of re-downloads', () async {
    final file = File('${tempDir.path}/a.m4a')..writeAsBytesSync([1]);
    await manager.enqueueTracksAtQuality(
        [track('alac', 'alac', filePath: file.path, downloadedQuality: '320')],
        quality: 'original');
    expect(manager.snapshot(), isEmpty);
  });
}
