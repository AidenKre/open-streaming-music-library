import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/repositories/queue_repository.dart';

import '../ui/browse_harness.dart' show SeedTrack, seedLibrary;

QueuePlaybackEntry entry(int id, {String? path}) => QueuePlaybackEntry(
  itemId: id, queueType: QueueItemTypes.main, canonicalPosition: id - 1,
  playPosition: id - 1, uuidId: 't$id', filePath: path,
);

class _Queue extends QueueRepository {
  _Queue(super.db);
  List<QueuePlaybackEntry> entries = [];
  int reads = 0;
  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntries(int sessionId, {
    int startPlayPosition = 0, int? limit,
  }) async {
    reads++;
    final rows = entries.where((e) => e.playPosition >= startPlayPosition);
    return (limit == null ? rows : rows.take(limit)).toList();
  }
  @override
  Future<QueuePlaybackEntry?> getPlaybackEntryForItem(int sessionId, int itemId) async {
    reads++;
    return entries.where((e) => e.itemId == itemId).firstOrNull;
  }
}

void main() {
  late AppDatabase db;
  late _Queue queue;
  late PlaybackTargetResolver resolver;
  final existing = <String>{};
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    queue = _Queue(db);
    existing.clear();
    resolver = PlaybackTargetResolver(queue, fileExists: (path) async => existing.contains(path));
  });
  tearDown(() => db.close());

  Future<PlaybackTargetResolution> start(int item, {bool offline = true}) =>
      resolver.resolveStart(sessionId: 1, preferredItemId: item,
        totalCount: queue.entries.length, offline: offline);

  test('online start keeps the chosen remote item', () async {
    queue.entries = [entry(1), entry(2, path: '/b')];
    existing.add('/b');
    final result = await start(1, offline: false);
    expect(result.target?.entry.itemId, 1);
    expect(result.target?.sourceKind, PlaybackSourceKind.remote);
  });

  test('offline start keeps a verified preferred local item', () async {
    queue.entries = [entry(1, path: '/a'), entry(2)];
    existing.add('/a');
    final result = await start(1);
    expect(result.target?.entry.itemId, 1);
    expect(result.target?.sourceKind, PlaybackSourceKind.local);
  });

  test('offline fallback prefers forward and returns missing-file issues', () async {
    queue.entries = [entry(1, path: '/a'), entry(2, path: '/missing'), entry(3, path: '/c')];
    existing.addAll(['/a', '/c']);
    final result = await start(2);
    expect(result.target?.entry.itemId, 3);
    final issue = result.issues.whereType<LocalFileMissing>().single;
    expect((issue.trackUuid, issue.path), ('t2', '/missing'));
  });

  test('offline fallback searches backward if nothing ahead is playable', () async {
    queue.entries = [entry(1, path: '/a'), entry(2), entry(3)];
    existing.add('/a');
    expect((await start(2)).target?.entry.itemId, 1);
  });

  test('a rejected resolution keeps its missing-file issues', () async {
    queue.entries = [entry(1, path: '/missing')];
    final result = await start(1);
    expect(result.target, isNull);
    expect(result.issues.whereType<LocalFileMissing>().single.path, '/missing');
  });

  test('online advance chooses adjacent entry, not a later local one', () async {
    queue.entries = [entry(1), entry(2), entry(3, path: '/c')];
    existing.add('/c');
    final result = await resolver.resolveAdvance(sessionId: 1,
      fromPlayPosition: 0, direction: PlayOrderDirection.forward,
      repeatMode: 'off', totalCount: 3, offline: false);
    expect(result.target?.entry.itemId, 2);
    expect(result.target?.sourceKind, PlaybackSourceKind.remote);
  });

  test('repeat-all wraps once; an all-unplayable queue terminates', () async {
    queue.entries = [entry(1, path: '/a'), entry(2)];
    existing.add('/a');
    Future<PlaybackTargetResolution> advance() => resolver.resolveAdvance(
      sessionId: 1, fromPlayPosition: 1, direction: PlayOrderDirection.forward,
      repeatMode: 'all', totalCount: 2, offline: true);
    expect((await advance()).target?.entry.itemId, 1);
    existing.clear();
    expect((await advance()).target, isNull);
  });

  test('an empty queue is rejected without lookup', () async {
    expect((await start(1)).target, isNull);
    expect(queue.reads, 0);
  });

  test('branch audit (5B.0b F6): offline, a missing preferred item still '
      'considers position 0', () async {
    queue.entries = [entry(1, path: '/a'), entry(2), entry(3)];
    existing.add('/a');
    expect((await start(99)).target?.entry.itemId, 1);
  });

  test('branch audit (5B.0b F10): online advance boundaries', () async {
    queue.entries = [entry(1), entry(2), entry(3)];
    Future<int?> adv(int from, PlayOrderDirection d, String repeat) async =>
        (await resolver.resolveAdvance(sessionId: 1, fromPlayPosition: from,
            direction: d, repeatMode: repeat, totalCount: 3, offline: false))
            .target?.entry.itemId;
    expect(await adv(2, PlayOrderDirection.forward, 'off'), isNull, reason: 'end, repeat off');
    expect(await adv(0, PlayOrderDirection.backward, 'all'), 3, reason: 'wraps backward');
    expect(await adv(2, PlayOrderDirection.forward, 'one'), isNull, reason: 'repeat one acts like off here');
  });

  test('online start rejects a missing preferred item', () async {
    queue.entries = [entry(1), entry(2, path: '/b')];
    existing.add('/b');
    expect((await start(99, offline: false)).target, isNull);
  });

  for (final hasFallback in [false, true]) {
    test('advance keeps missing-file issues, fallback=$hasFallback', () async {
      queue.entries = [entry(1), entry(2, path: '/missing'), entry(3, path: '/c')];
      if (hasFallback) existing.add('/c');
      final result = await resolver.resolveAdvance(sessionId: 1,
        fromPlayPosition: 0, direction: PlayOrderDirection.forward,
        repeatMode: 'off', totalCount: 3, offline: true);
      expect(result.target?.entry.itemId, hasFallback ? 3 : null);
      final missing = result.issues.whereType<LocalFileMissing>()
          .where((issue) => issue.trackUuid == 't2').toList();
      expect(missing, hasLength(1),
          reason: 'the skipped missing file is reported once');
      expect(missing.single.path, '/missing');
    });
  }

  test('the decision waits for an async file check', () async {
    queue.entries = [entry(1, path: '/a'), entry(2)];
    final stat = Completer<bool>();
    final slow = PlaybackTargetResolver(queue, fileExists: (_) => stat.future);
    var decided = false;
    final pending = slow.resolveStart(sessionId: 1, preferredItemId: 1,
        totalCount: 2, offline: true).then((r) {
      decided = true;
      return r;
    });
    await pumpEventQueue();
    expect(decided, isFalse, reason: 'no decision before the stat answers');
    stat.complete(true);
    final result = await pending;
    expect(result.target?.sourceKind, PlaybackSourceKind.local);
    expect(result.issues, isEmpty);
  });

  // Review major 1: the resolver uses the playback policy, so a download in a
  // codec this device can't decode, or one suspected after a failure, is not
  // a local target (offline it is skipped, never retried as a file).
  test('offline, an undecodable or suspected download is skipped', () async {
    final policy = LocalSourcePolicy(
        codecs: const CodecSupport({AudioCodecFamily.mp3}));
    final withPolicy = PlaybackTargetResolver(queue,
        fileExists: (path) async => existing.contains(path),
        localSources: policy);
    queue.entries = [
      QueuePlaybackEntry(itemId: 1, queueType: QueueItemTypes.main,
          canonicalPosition: 0, playPosition: 0, uuidId: 't1',
          filePath: '/a', downloadedCodec: 'flac'),
      entry(2, path: '/b'),
      entry(3, path: '/c'),
    ];
    existing.addAll(['/a', '/b', '/c']);
    policy.suspect('t2', '/b');
    final result = await withPolicy.resolveStart(sessionId: 1,
        preferredItemId: 1, totalCount: 3, offline: true);
    expect(result.target?.entry.itemId, 3);
    expect(result.issues, isEmpty, reason: 'neither file is missing');
  });
  // 6A.2 (R1-1, amends DEV-6-02): offline, an Enqueue into an active queue
  // keeps only the members that play from a local file, by the same rule a
  // landing target uses (usable download, decodable codec, the file on disk).
  group('filterPlayableOffline', () {
    late AppDatabase library;
    late PlaybackTargetResolver filter;
    final onDisk = <String>{};

    Future<void> download(String uuid, String codec,
        {bool damaged = false}) async {
      final path = '/dl/$uuid.$codec';
      await (library.update(library.tracks)
            ..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(
        filePath: Value(path),
        downloadedAtRevision: const Value(1),
        downloadedCodec: Value(codec),
        damagedFilePath: Value(damaged ? path : null),
      ));
    }

    setUp(() async {
      library = AppDatabase(NativeDatabase.memory());
      await seedLibrary(library, [
        for (final u in ['p1', 'p2', 'x1', 'm1', 'r1', 'd1', 'n1'])
          SeedTrack(uuid: u, title: u, artistId: 1, artist: 'Ann',
              albumId: 1, album: 'A'),
      ]);
      onDisk.clear();
      filter = PlaybackTargetResolver(QueueRepository(library),
          fileExists: (path) async => onDisk.contains(path),
          localSources: LocalSourcePolicy(
              codecs: const CodecSupport({AudioCodecFamily.mp3})));
    });
    tearDown(() => library.close());

    test('keeps decodable downloads on disk, in order, and drops the rest',
        () async {
      await download('p1', 'mp3');
      await download('p2', 'mp3');
      await download('x1', 'flac'); // undecodable on this device
      await download('m1', 'mp3'); // recorded, missing on disk
      await download('d1', 'mp3', damaged: true);
      // r1: never downloaded.
      onDisk.addAll(['/dl/p1.mp3', '/dl/p2.mp3', '/dl/x1.flac', '/dl/d1.mp3']);
      final result = await filter
          .filterPlayableOffline(['p2', 'x1', 'm1', 'r1', 'd1', 'p1']);
      expect(result.playable, ['p2', 'p1']);
      expect(result.issues, hasLength(1));
      final issue = result.issues.single as LocalFileMissing;
      expect(issue.trackUuid, 'm1');
      expect(issue.path, '/dl/m1.mp3');
    });

    test('a duplicate member stays duplicated', () async {
      await download('p1', 'mp3');
      onDisk.add('/dl/p1.mp3');
      final result = await filter.filterPlayableOffline(['p1', 'p1']);
      expect(result.playable, ['p1', 'p1']);
    });

    test('nothing playable gives an empty list', () async {
      await download('x1', 'flac');
      onDisk.add('/dl/x1.flac');
      final result = await filter.filterPlayableOffline(['x1', 'r1', 'n1']);
      expect(result.playable, isEmpty);
      expect(result.issues, isEmpty);
    });

    test('a uuid unknown to the library is dropped', () async {
      final result = await filter.filterPlayableOffline(['gone']);
      expect(result.playable, isEmpty);
    });

    test('a suspected download is not played from its file', () async {
      final policy = LocalSourcePolicy();
      final suspicious = PlaybackTargetResolver(QueueRepository(library),
          fileExists: (path) async => onDisk.contains(path),
          localSources: policy);
      await download('p1', 'mp3');
      await download('p2', 'mp3');
      onDisk.addAll(['/dl/p1.mp3', '/dl/p2.mp3']);
      policy.suspect('p1', '/dl/p1.mp3');
      final result = await suspicious.filterPlayableOffline(['p1', 'p2']);
      expect(result.playable, ['p2']);
    });
  });
}
