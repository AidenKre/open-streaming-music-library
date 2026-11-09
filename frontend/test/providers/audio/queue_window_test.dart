import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/audio/queue_window.dart';
import 'package:frontend/repositories/queue_repository.dart';

class _Queue extends QueueRepository {
  _Queue(super.db);
  final entries = List.generate(120, (i) => QueuePlaybackEntry(
    itemId: i + 1, queueType: QueueItemTypes.main, canonicalPosition: i,
    playPosition: i, uuidId: 't$i',
  ));
  int reads = 0;
  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntries(int sessionId, {
    int startPlayPosition = 0, int? limit,
  }) async {
    reads++;
    final rows = entries.where((e) => e.playPosition >= startPlayPosition);
    return (limit == null ? rows : rows.take(limit)).toList();
  }
}

void main() {
  late AppDatabase db;
  late _Queue queue;
  late QueueWindow window;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    queue = _Queue(db);
    window = QueueWindow(queue);
  });
  tearDown(() async {
    window.dispose();
    await db.close();
  });

  test('seed query preserves the 12-before, 48-after bounded window', () async {
    final rows = await window.seedEntriesForPlayPosition(1, 40);
    expect(rows.map((e) => e.playPosition), List.generate(61, (i) => i + 28));
    expect(window.nextForwardHydrationPlayPosition, 0, reason: 'read is only a proposal');
  });

  test('an already loaded item needs no proposal or row read', () async {
    expect(await window.proposeItemLoad(1, queue.entries[20], alreadyLoaded: true), isNull);
    expect(queue.reads, 0);
  });

  test('an extension changes coverage only when acknowledged', () async {
    final proposal = (await window.proposeItemLoad(1, queue.entries[40], alreadyLoaded: false))!;
    expect(proposal.entries.map((e) => e.playPosition), List.generate(61, (i) => i + 28));
    expect(window.nextForwardHydrationPlayPosition, 0);
    window.acknowledge(proposal);
    expect(window.nextForwardHydrationPlayPosition, 89);
  });

  test('extension acknowledgement preserves farther existing coverage', () {
    window.nextForwardHydrationPlayPosition = 100;
    window.acknowledge(const QueueWindowProposal([], 20));
    expect(window.nextForwardHydrationPlayPosition, 100);
  });

  test('explicit replacement acknowledges the supplied coverage', () {
    window.nextForwardHydrationPlayPosition = 100;
    window.acknowledge(const QueueWindowProposal([], 20, replaceCoverage: true));
    expect(window.nextForwardHydrationPlayPosition, 20);
  });

  test('forward hydration proposes one 50-item chunk and awaits application', () async {
    window.nextForwardHydrationPlayPosition = 5;
    final entered = Completer<QueueWindowProposal>();
    final release = Completer<void>();
    final applied = Completer<void>();
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120, currentPlayPosition: 0,
      apply: (proposal) async {
        entered.complete(proposal);
        await release.future;
        window.acknowledge(proposal);
        applied.complete();
      });
    final proposal = await entered.future;
    expect(proposal.entries.map((e) => e.playPosition), List.generate(50, (i) => i + 5));
    expect(window.nextForwardHydrationPlayPosition, 5);
    release.complete();
    await applied.future;
    await pumpEventQueue();
    expect(window.nextForwardHydrationPlayPosition, 55);
    expect(queue.reads, 1, reason: 'buffer now exceeds the threshold');
  });

  test('a full buffer, exhausted queue or disposed window schedules nothing', () async {
    var applications = 0;
    Future<void> apply(QueueWindowProposal _) async => applications++;
    window.nextForwardHydrationPlayPosition = 80;
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120, currentPlayPosition: 0, apply: apply);
    window.nextForwardHydrationPlayPosition = 120;
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120, currentPlayPosition: 100, apply: apply);
    window.dispose();
    window.nextForwardHydrationPlayPosition = 0;
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120, currentPlayPosition: 0, apply: apply);
    await pumpEventQueue();
    expect(queue.reads, 0);
    expect(applications, 0);
  });
}
