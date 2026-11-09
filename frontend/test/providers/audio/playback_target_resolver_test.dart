import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/audio/playback_target_resolver.dart';
import 'package:frontend/repositories/queue_repository.dart';

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
    resolver = PlaybackTargetResolver(queue, fileExists: existing.contains);
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
}
