// What a listed search result shows after each download event (pre-Phase-10
// download-state tidy): a download starts, finishes, fails, is marked
// damaged, is removed. Real database, real repository, real search
// controller; the rows change as the app writes them. Pinned before the
// search results stopped patching download columns by hand, and unchanged by
// that change.
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download/download_reconciliation_service.dart';
import 'package:frontend/services/download/download_status_reader.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;

/// What a track row in the results shows: its download state and its title.
typedef _Shown = ({
  bool downloaded,
  bool damaged,
  bool stale,
  String? filePath,
  String? quality,
  String? codec,
  int? bitrate,
  int? size,
  String? title,
});

_Shown _shown(TrackUI t) => (
  downloaded: t.isDownloaded,
  damaged: t.isDownloadDamaged,
  stale: t.isStaleDownload,
  filePath: t.filePath,
  quality: t.downloadedQuality,
  codec: t.downloadedCodec,
  bitrate: t.downloadedBitrateKbps,
  size: t.fileSizeBytes,
  title: t.title,
);

const _notDownloaded = (
  downloaded: false,
  damaged: false,
  stale: false,
  filePath: null,
  quality: null,
  codec: null,
  bitrate: null,
  size: null,
  title: 'Blue One',
);

const _b1Path = '/downloads/b1.m4a';

const _finished = (
  downloaded: true,
  damaged: false,
  stale: false,
  filePath: _b1Path,
  quality: '320',
  codec: 'aac',
  bitrate: 256,
  size: 4096,
  title: 'Blue One',
);

const _damaged = (
  downloaded: false,
  damaged: true,
  stale: false,
  filePath: _b1Path,
  quality: '320',
  codec: 'aac',
  bitrate: 256,
  size: 4096,
  title: 'Blue One',
);

const _b2 = (
  downloaded: true,
  damaged: false,
  stale: false,
  filePath: '/downloads/b2.flac',
  quality: null,
  codec: null,
  bitrate: null,
  size: null,
  title: 'Blue Two',
);

void main() {
  late AppDatabase db;
  late DownloadStatusReader reader;
  var downloadedOnly = false;

  setUp(() async {
    downloadedOnly = false;
    db = AppDatabase(NativeDatabase.memory());
    reader = DownloadStatusReader();
    await seedLibrary(db, const [
      SeedTrack(uuid: 'b1', title: 'Blue One', artistId: 1, artist: 'X'),
      SeedTrack(
        uuid: 'b2',
        title: 'Blue Two',
        artistId: 1,
        artist: 'X',
        downloaded: true,
      ),
      SeedTrack(uuid: 'r1', title: 'Red', artistId: 1, artist: 'X'),
    ]);
  });

  tearDown(() async {
    reader.dispose();
    await db.close();
  });

  Future<LibrarySearchController> searchBlue() async {
    final c = LibrarySearchController(
      repository: BrowseRepository(db),
      types: const {SearchType.tracks},
      limitPerType: 100,
      downloadedOnly: () => downloadedOnly,
    );
    addTearDown(c.dispose);
    final settled = Completer<void>();
    void onChange() {
      if (!c.isSearching && !settled.isCompleted) settled.complete();
    }

    c.addListener(onChange);
    c.submit('Blue');
    await settled.future;
    c.removeListener(onChange);
    return c;
  }

  /// A download event reaching the open search, as the pages pass it on.
  /// A download-filtered search searches again; wait for it to land.
  Future<void> event(LibrarySearchController c) async {
    if (!downloadedOnly) return c.onDownloadStatusChanged();
    final settled = Completer<void>();
    void onChange() {
      if (!c.isSearching && !settled.isCompleted) settled.complete();
    }

    c.addListener(onChange);
    await c.onDownloadStatusChanged();
    if (c.isSearching) await settled.future;
    c.removeListener(onChange);
  }

  List<String> uuids(LibrarySearchController c) =>
      [for (final t in c.results.tracks) t.uuidId];

  Map<String, _Shown> shown(LibrarySearchController c) =>
      {for (final t in c.results.tracks) t.uuidId: _shown(t)};

  /// The columns the download commit writes (`TrackDownloader`'s swap).
  Future<void> finishDownload() =>
      (db.update(db.tracks)..where((t) => t.uuidId.equals('b1'))).write(
        const TracksCompanion(
          filePath: Value(_b1Path),
          downloadedBitrateKbps: Value(256),
          fileSizeBytes: Value(4096),
          downloadedQuality: Value('320'),
          downloadedAtRevision: Value(1),
          downloadedCodec: Value('aac'),
          staleDismissedAtRevision: Value(null),
          damagedFilePath: Value(null),
        ),
      );

  Future<void> markDamaged() async {
    final marked = await DownloadReconciliationService(
      db: db,
      statusReader: reader,
    ).markDamaged('b1', _b1Path);
    expect(marked, isTrue);
  }

  Future<void> removeDownload() =>
      (db.update(db.tracks)..where((t) => t.uuidId.equals('b1')))
          .write(clearedDownloadColumns);

  test('an unfiltered search shows each download event on the listed row, '
      'in place', () async {
    final c = await searchBlue();
    final order = uuids(c);
    expect(order, unorderedEquals(['b1', 'b2']));
    expect(shown(c), {'b1': _notDownloaded, 'b2': _b2});

    // A download starts: nothing is stored yet.
    await event(c);
    expect(shown(c), {'b1': _notDownloaded, 'b2': _b2});

    await finishDownload();
    await event(c);
    expect(shown(c), {'b1': _finished, 'b2': _b2});

    await markDamaged();
    await event(c);
    expect(shown(c), {'b1': _damaged, 'b2': _b2});

    await removeDownload();
    await event(c);
    expect(shown(c), {'b1': _notDownloaded, 'b2': _b2});

    // A second download starts and fails: it stores nothing.
    await event(c);
    await event(c);
    expect(shown(c), {'b1': _notDownloaded, 'b2': _b2});

    expect(uuids(c), order, reason: 'rows stay in place');
  });

  test('a listed track that left the library stays listed as it was',
      () async {
    final c = await searchBlue();
    final order = uuids(c);
    await (db.delete(db.trackmetadata)..where((t) => t.uuidId.equals('b2')))
        .go();
    await (db.delete(db.tracks)..where((t) => t.uuidId.equals('b2'))).go();
    await finishDownload();

    await event(c);

    expect(uuids(c), order);
    expect(shown(c), {'b1': _finished, 'b2': _b2});
  });

  test('a download-filtered search: a finished download joins, a damaged or '
      'removed one leaves', () async {
    downloadedOnly = true;
    final c = await searchBlue();
    expect(shown(c), {'b2': _b2});

    await finishDownload();
    await event(c);
    expect(shown(c), {'b1': _finished, 'b2': _b2});

    await markDamaged();
    await event(c);
    expect(shown(c), {'b2': _b2});

    await removeDownload();
    await event(c);
    expect(shown(c), {'b2': _b2});
  });
}
