import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/playback/queue_window.dart';
import 'package:frontend/repositories/queue_repository.dart';
import '../helpers/server_binding.dart';
import '../helpers/library_fixture.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late _FakePlayer fakePlayer;
  late QueueWindow hydration;
  late LibraryFixture fixture;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    repo = QueueRepository(db);
    fakePlayer = _FakePlayer();
    hydration = QueueWindow(repo);
    fixture = LibraryFixture(db);
  });

  tearDown(() async {
    hydration.dispose();
    fakePlayer.dispose();
    await db.close();
  });

  test('seedEntriesForPlayPosition returns bounded window', () async {
    await fixture.insertSingles(List.generate(80, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(80, (i) => 'track-${i + 1}'),
      currentIndex: 40,
    );

    final entries = await hydration.seedEntriesForPlayPosition(sessionId, 40);

    expect(entries, isNotEmpty);
    expect(entries.length,
        lessThanOrEqualTo(
            QueueWindow.seedPreviousCount +
            QueueWindow.seedNextCount + 1));
    expect(entries.first.playPosition,
        greaterThanOrEqualTo(40 - QueueWindow.seedPreviousCount));
    expect(entries.any((e) => e.playPosition == 40), isTrue);
  });

  // 5B.0d: loading an item outside the window is a rebase by the core
  // (queue_player_test 'a distant jump rebases ...'); the window only
  // proposes seeds and records the replaced interval.
  test('a rebase seed is the bounded window around the target', () async {
    await fixture.insertSingles(List.generate(80, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(80, (i) => 'track-${i + 1}'),
      currentIndex: 0,
    );
    final entries = await hydration.seedEntriesForPlayPosition(sessionId, 70);
    expect(entries.first.playPosition, 70 - QueueWindow.seedPreviousCount);
    expect(entries.last.playPosition, 79);
    hydration.replaceWindow(
        start: entries.first.playPosition, end: entries.last.playPosition + 1);
    expect(hydration.windowStartPlayPosition, 58);
    expect(hydration.nextForwardHydrationPlayPosition, 80);
    expect(hydration.coversQueue(80), isFalse);
  });

  test('a window over every row covers the queue', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 0,
    );
    final entries = await hydration.seedEntriesForPlayPosition(sessionId, 0);
    hydration.replaceWindow(start: 0, end: entries.last.playPosition + 1);
    expect(hydration.coversQueue(3), isTrue);
  });

  test('scheduleForwardHydration loads when buffer is low', () async {
    await fixture.insertSingles(List.generate(100, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(100, (i) => 'track-${i + 1}'),
      currentIndex: 0,
    );

    hydration.replaceWindow(start: 0, end: 5);
    hydration.scheduleForwardHydration(
      sessionId: sessionId,
      totalCount: 100,
      currentPlayPosition: 0,
      apply: (proposal) async {
        await fakePlayer.addEntries(proposal.entries);
        return hydration.acknowledge(proposal);
      },
    );

    await fakePlayer.firstAdd.future;
    await pumpEventQueue();

    expect(fakePlayer.addedBatches, isNotEmpty);
    expect(hydration.nextForwardHydrationPlayPosition, greaterThan(5));
  });

  test('reset sets hydration position to 0', () {
    hydration.nextForwardHydrationPlayPosition = 42;
    hydration.reset();
    expect(hydration.nextForwardHydrationPlayPosition, 0);
  });
}

class _FakePlayer {
  final Set<int> _loadedItemIds = {};
  final List<List<QueuePlaybackEntry>> addedBatches = [];
  final firstAdd = Completer<void>();
  void preloadItems(List<QueuePlaybackEntry> entries) =>
      _loadedItemIds.addAll(entries.map((entry) => entry.itemId));
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    final additions = entries.where((entry) => !_loadedItemIds.contains(entry.itemId)).toList();
    if (additions.isEmpty) return;
    addedBatches.add(additions);
    preloadItems(additions);
    if (!firstAdd.isCompleted) firstAdd.complete();
  }
  bool hasItem(int itemId) => _loadedItemIds.contains(itemId);
  void dispose() {}
}
