import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/download/download_queue.dart';

DownloadJob _job(String uuidId, {DownloadStatus? status}) => DownloadJob(
  uuidId: uuidId,
  title: 't$uuidId',
  artist: 'a',
  quality: 'original',
  status: status ?? const Queued(),
);

void main() {
  late DownloadQueue queue;
  late int notifyCount;

  setUp(() {
    queue = DownloadQueue();
    notifyCount = 0;
    queue.addListener(() => notifyCount++);
  });

  tearDown(() => queue.dispose());

  test('starts empty', () {
    expect(queue.state.jobs, isEmpty);
    expect(queue.snapshot(), isEmpty);
    expect(queue.findFirstQueuedIndex(), -1);
  });

  test('addAll appends jobs and notifies once', () {
    queue.addAll([_job('a'), _job('b')]);
    expect(queue.state.jobs.map((j) => j.uuidId), ['a', 'b']);
    expect(notifyCount, 1);
  });

  test('addAll of an empty list is a no-op (no notification)', () {
    queue.addAll(const []);
    expect(notifyCount, 0);
    expect(queue.state.jobs, isEmpty);
  });

  test('markJob replaces in place and notifies', () {
    queue.addAll([_job('a'), _job('b')]);
    final before = notifyCount;
    queue.markJob(0, _job('a', status: const Active(progress: 0.5)));
    expect(queue.jobAt(0).isActive, isTrue);
    expect(notifyCount, before + 1);
  });

  test('markJobByUuid no-ops when uuid is missing', () {
    queue.addAll([_job('a')]);
    final before = notifyCount;
    queue.markJobByUuid('missing', (j) => j.withStatus(const Active()));
    expect(notifyCount, before);
  });

  test('findFirstQueuedIndex skips active/completed entries', () {
    queue.addAll([
      _job('a', status: const Active()),
      _job('b', status: const Completed(sizeBytes: 100)),
      _job('c'),
    ]);
    expect(queue.findFirstQueuedIndex(), 2);
  });

  test('clearFinished drops completed + failed, keeps queued + active', () {
    queue.addAll([
      _job('a', status: const Completed(sizeBytes: 1)),
      _job('b', status: const Active(progress: 0.1)),
      _job('c', status: const Failed(message: 'x')),
      _job('d'),
    ]);
    queue.clearFinished();
    expect(queue.state.jobs.map((j) => j.uuidId), ['b', 'd']);
  });

  test('cancelQueued removes a queued job', () {
    queue.addAll([_job('a'), _job('b')]);
    queue.cancelQueued('a');
    expect(queue.state.jobs.map((j) => j.uuidId), ['b']);
  });

  test('cancelQueued is a no-op for active jobs (intentional)', () {
    queue.addAll([_job('a', status: const Active())]);
    final before = notifyCount;
    queue.cancelQueued('a');
    expect(queue.state.jobs.length, 1);
    expect(notifyCount, before);
  });

  test('clearAll empties the queue and notifies', () {
    queue.addAll([_job('a'), _job('b')]);
    final before = notifyCount;
    queue.clearAll();
    expect(queue.state.jobs, isEmpty);
    expect(notifyCount, before + 1);
  });
}
