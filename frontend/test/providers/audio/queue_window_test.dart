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
  Completer<void>? readGate;
  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntries(int sessionId, {
    int startPlayPosition = 0, int? limit,
  }) async {
    reads++;
    await readGate?.future;
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

  test('a replacement sets the contiguous interval and a new revision', () {
    final before = window.windowRevision;
    window.replaceWindow(start: 28, end: 89);
    expect(window.windowStartPlayPosition, 28);
    expect(window.nextForwardHydrationPlayPosition, 89);
    expect(window.windowRevision, greaterThan(before));
    expect(window.coversQueue(120), isFalse);
    window.replaceWindow(start: 0, end: 120);
    expect(window.coversQueue(120), isTrue);
  });

  test('an extension changes coverage only when acknowledged', () {
    window.replaceWindow(start: 0, end: 20);
    final proposal = QueueWindowProposal(const [], 70,
        windowRevision: window.windowRevision);
    expect(window.nextForwardHydrationPlayPosition, 20);
    expect(window.acknowledge(proposal), isTrue);
    expect(window.nextForwardHydrationPlayPosition, 70);
  });

  test('extension acknowledgement preserves farther existing coverage', () {
    window.replaceWindow(start: 0, end: 100);
    window.acknowledge(
        QueueWindowProposal(const [], 20, windowRevision: window.windowRevision));
    expect(window.nextForwardHydrationPlayPosition, 100);
  });

  test('a proposal of a replaced window is not acknowledged', () {
    window.replaceWindow(start: 0, end: 20);
    final stale = QueueWindowProposal(const [], 70,
        windowRevision: window.windowRevision);
    window.replaceWindow(start: 50, end: 60);
    expect(window.acknowledge(stale), isFalse);
    expect(window.nextForwardHydrationPlayPosition, 60);
  });

  test('forward hydration proposes one 50-item chunk and awaits application', () async {
    window.replaceWindow(start: 0, end: 5);
    final entered = Completer<QueueWindowProposal>();
    final release = Completer<void>();
    final applied = Completer<void>();
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120, currentPlayPosition: 0,
      apply: (proposal) async {
        entered.complete(proposal);
        await release.future;
        window.acknowledge(proposal);
        applied.complete();
        return true;
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

  test('a chunk read across a replacement is dropped; a newer request runs',
      () async {
    window.replaceWindow(start: 0, end: 5);
    final proposals = <QueueWindowProposal>[];
    queue.readGate = Completer<void>();
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120,
        currentPlayPosition: 0, apply: (p) async {
      proposals.add(p);
      return false;
    });
    window.replaceWindow(start: 40, end: 50);
    window.scheduleForwardHydration(sessionId: 1, totalCount: 120,
        currentPlayPosition: 40, context: 'fresh', apply: (p) async {
      proposals.add(p);
      return false;
    });
    queue.readGate!.complete();
    queue.readGate = null;
    await pumpEventQueue();
    expect(proposals.map((p) => p.context), ['fresh'],
        reason: 'the read across the replacement proposes nothing');
    expect(proposals.single.entries.first.playPosition, 50);
    expect(proposals.single.windowRevision, window.windowRevision);
  });

  test('a full buffer, exhausted queue or disposed window schedules nothing', () async {
    var applications = 0;
    Future<bool> apply(QueueWindowProposal _) async {
      applications++;
      return true;
    }
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
