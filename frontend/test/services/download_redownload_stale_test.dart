import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';

TrackUI _t(String uuid, String? quality) => TrackUI(
  uuidId: uuid,
  filePath: '/f/$uuid',
  downloadedQuality: quality,
  createdAt: 0,
  lastUpdated: 0,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

class _Recording extends DownloadManager {
  _Recording(AppDatabase db, LocalCoverArtStore store, Directory dir, this.failing)
    : super(db: db, coverArtStore: store, directoryProvider: () async => dir);
  final Set<String> failing;
  final calls = <String>[];
  @override
  Future<void> enqueueTracksAtQuality(
    List<TrackUI> tracks, {
    required String quality,
    bool force = false,
  }) async {
    if (failing.contains(quality)) throw StateError('queue $quality');
    calls.add('$quality force=$force ${tracks.map((t) => t.uuidId).join(',')}');
  }
}

/// The stale re-download rule (formerly in StaleDownloadsBanner; SC-26).
void main() {
  late AppDatabase db;
  late Directory dir;
  late LocalCoverArtStore store;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('redownload');
    store = await LocalCoverArtStore.create(directoryProvider: () async => dir);
  });
  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('each track re-downloads at its stored quality, forced, grouped; an '
      'invalid stored quality falls back', () async {
    final m = _Recording(db, store, dir, const {});
    addTearDown(m.dispose);
    final failed = await m.redownloadStale(
      [_t('a', '192'), _t('b', 'bogus'), _t('c', '192'), _t('d', null)],
      fallbackQuality: '320',
    );
    expect(failed, 0);
    expect(m.calls, ['192 force=true a,c', '320 force=true b,d']);
  });

  test('a failing group is counted and does not stop the others', () async {
    final m = _Recording(db, store, dir, const {'192'});
    addTearDown(m.dispose);
    final failed = await m.redownloadStale(
      [_t('a', '192'), _t('b', 'original'), _t('c', '192')],
      fallbackQuality: '320',
    );
    expect(failed, 2);
    expect(m.calls, ['original force=true b']);
  });
}
