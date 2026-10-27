import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';

Map<String, dynamic> _jobJson({
  int jobId = 1,
  String uuidId = 'abc',
  String status = 'queued',
  String? errorText,
}) => {
  'job_id': jobId,
  'uuid_id': uuidId,
  'target_codec': 'aac',
  'target_container': 'm4a',
  'target_bitrate': 192,
  'status': status,
  'error_text': errorText,
  'created_at': 1000,
  'updated_at': 1000,
};

/// In-memory `/jobs` backend implementing the real contract: comma-separated
/// `status`, `uuid_id`, exclusive ascending `cursor`, `limit`, and a non-null
/// `nextCursor` when the page was full.
class _FakeJobsServer {
  final Map<int, Map<String, dynamic>> jobs = {};
  final List<Uri> getRequests = [];
  int postCount = 0;
  int deleteCount = 0;

  /// When set, the next GETs answer with this status code instead.
  final List<int> failNextGetsWith = [];

  /// When set, GETs wait on this before answering (simulates in-flight).
  Completer<void>? holdGets;

  /// When true, a held GET's response is computed when the request ARRIVES
  /// (before the hold) -- models a response already on the wire while local
  /// state changes underneath it.
  bool snapshotBeforeHold = false;

  Map<String, dynamic> nextPostResponse = _jobJson();

  void put(Map<String, dynamic> job) => jobs[job['job_id'] as int] = job;

  void setStatus(int jobId, String status) =>
      jobs[jobId] = {...jobs[jobId]!, 'status': status};

  /// GETs that fetched the whole active set (vs a per-job settle lookup).
  int get activeSetGets => getRequests
      .where((u) => u.queryParameters['status'] == activeJobStatuses)
      .length;

  MockClient get client => MockClient((req) async {
    switch (req.method) {
      case 'POST':
        postCount++;
        put(nextPostResponse);
        return http.Response(jsonEncode(nextPostResponse), 200);
      case 'DELETE':
        deleteCount++;
        final id = int.parse(req.url.pathSegments.last);
        final job = jobs[id];
        final active =
            job != null && (job['status'] == 'queued' || job['status'] == 'running');
        if (active) setStatus(id, 'cancelled');
        return http.Response(jsonEncode({'cancelled': active}), 200);
      case 'GET':
        getRequests.add(req.url);
        final hold = holdGets;
        final early =
            snapshotBeforeHold ? jsonEncode(_page(req.url.queryParameters)) : null;
        if (hold != null) await hold.future;
        if (failNextGetsWith.isNotEmpty) {
          return http.Response('boom', failNextGetsWith.removeAt(0));
        }
        return http.Response(
          early ?? jsonEncode(_page(req.url.queryParameters)),
          200,
        );
    }
    return http.Response('unexpected', 500);
  });

  Map<String, dynamic> _page(Map<String, String> q) {
    final statuses = q['status']?.split(',').toSet();
    final uuid = q['uuid_id'];
    final cursor = int.tryParse(q['cursor'] ?? '') ?? 0;
    final limit = int.parse(q['limit'] ?? '50');
    final ids = jobs.keys.toList()..sort();
    final matching = [
      for (final id in ids)
        if (id > cursor &&
            (uuid == null || jobs[id]!['uuid_id'] == uuid) &&
            (statuses == null || statuses.contains(jobs[id]!['status'])))
          jobs[id]!,
    ];
    final page = matching.take(limit).toList();
    return {
      'data': page,
      'nextCursor': page.length == limit ? page.last['job_id'] : null,
    };
  }
}

class _Offline extends OfflineModeNotifier {
  _Offline(this.initial);
  final bool initial;

  @override
  bool build() => initial;

  void set(bool value) => state = value;
}

class _CountingSync extends TrackSyncNotifier {
  int syncFreshCalls = 0;

  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}

  @override
  Future<bool> syncFresh() async {
    syncFreshCalls++;
    return true;
  }
}

class _Harness {
  _Harness(this.container, this.server, this.sync, this.offline) {
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => printed.add('$message');
  }
  final ProviderContainer container;
  final _FakeJobsServer server;
  final _CountingSync sync;
  final _Offline offline;

  /// debugPrint output captured while the harness is open (the notifier
  /// logs caught poll failures through it).
  final List<String> printed = [];
  late final DebugPrintCallback _originalDebugPrint;
  bool _disposed = false;

  void disposeContainer() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
  }

  /// Disposes the container and restores debugPrint -- must run inside the
  /// test body (the binding verifies debugPrint is restored before
  /// tearDown).
  void close() {
    disposeContainer();
    debugPrint = _originalDebugPrint;
  }

  ConversionJobsNotifier get notifier =>
      container.read(conversionJobsProvider.notifier);
  List<ConversionJob> get jobs => container.read(conversionJobsProvider);

  Future<ConversionJob> enqueue() => notifier.enqueue(
    uuidId: 'abc',
    targetCodec: 'aac',
    targetBitrateKbps: 192,
    baseRevision: 1,
  );
}

_Harness _harness({bool offline = false, _FakeJobsServer? server}) {
  final s = server ?? _FakeJobsServer();
  ApiClient.initForTest('http://localhost:8000', s.client);
  final sync = _CountingSync();
  final off = _Offline(offline);
  final container = ProviderContainer(
    overrides: [
      trackSyncProvider.overrideWith(() => sync),
      offlineModeProvider.overrideWith(() => off),
    ],
  );
  // Materialise the stubs so `sync`/`off` are the live instances.
  container.read(offlineModeProvider);
  container.read(trackSyncProvider);
  return _Harness(container, s, sync, off);
}

const _interval = Duration(seconds: 1);

/// Tracks the timers created by code running inside [run] (the notifier's
/// poll timers are created in the zone of the call that scheduled them, and
/// each poll's continuation re-schedules from that same zone).
class _TimerTracker {
  final List<Timer> _timers = [];

  int get pending => _timers.where((t) => t.isActive).length;

  Future<T> run<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createTimer(zone, duration, callback);
        _timers.add(timer);
        return timer;
      },
    ),
  );
}

void main() {
  setUp(() {
    ConversionJobsNotifier.pollInterval = _interval;
    ConversionJobsNotifier.maxPollBackoff = const Duration(seconds: 30);
    ConversionJobsNotifier.activePageSize = 50;
  });

  tearDown(() {
    ConversionJobsNotifier.pollInterval = const Duration(seconds: 3);
    ConversionJobsNotifier.activePageSize = 50;
  });

  // testWidgets for its FakeAsync zone: `tester.pump(d)` advances the poll
  // timers deterministically. Each test disposes its container before
  // returning so no timer outlives it (the framework fails on a pending
  // timer, which also proves dispose cancels polling).

  testWidgets('starts with an empty job list', (tester) async {
    final h = _harness();
    expect(h.jobs, isEmpty);
    h.close();
  });

  testWidgets('enqueue adds the new job to state', (tester) async {
    final h = _harness();
    final job = await h.enqueue();

    expect(job.jobId, 1);
    expect(h.jobs, [job]);
    h.close();
  });

  testWidgets('polls on the interval, follows the transition, stops when terminal',
      (tester) async {
    final h = _harness();
    await h.enqueue();
    expect(h.server.getRequests, isEmpty);

    await tester.pump(_interval);
    expect(h.server.activeSetGets, 1);
    expect(h.jobs.single.isQueued, isTrue);

    h.server.setStatus(1, 'running');
    await tester.pump(_interval);
    expect(h.jobs.single.isRunning, isTrue);

    h.server.setStatus(1, 'done');
    await tester.pump(_interval);
    expect(h.jobs.single.isDone, isTrue);

    final gets = h.server.getRequests.length;
    await tester.pump(_interval * 10);
    expect(h.server.getRequests.length, gets,
        reason: 'no further polling once nothing is active');
    h.close();
  });

  testWidgets('a failed poll keeps polling with backoff, then recovers',
      (tester) async {
    final h = _harness();
    h.server.failNextGetsWith.addAll([500, 500]);
    await h.enqueue();
    h.server.setStatus(1, 'done');

    await tester.pump(_interval); // t=1s: fails (backoff -> 2s)
    expect(h.server.getRequests, hasLength(1));
    expect(h.jobs.single.isQueued, isTrue);
    expect(h.printed.join(), contains('poll failed'));

    await tester.pump(const Duration(milliseconds: 1900)); // t=2.9s
    expect(h.server.getRequests, hasLength(1), reason: 'backed off to 2s');
    await tester.pump(const Duration(milliseconds: 100)); // t=3s: fails (-> 4s)
    expect(h.server.getRequests, hasLength(2));

    await tester.pump(const Duration(milliseconds: 3900)); // t=6.9s
    expect(h.server.getRequests, hasLength(2), reason: 'backed off to 4s');
    await tester.pump(const Duration(milliseconds: 100)); // t=7s: succeeds
    expect(h.jobs.single.isDone, isTrue);
    h.close();
  });

  testWidgets('backoff resets after a success', (tester) async {
    final h = _harness();
    h.server.failNextGetsWith.add(500);
    await h.enqueue();

    await tester.pump(_interval); // fail -> next in 2s
    await tester.pump(_interval * 2); // success -> next in 1s
    final afterRecovery = h.server.activeSetGets;
    await tester.pump(_interval);
    expect(h.server.activeSetGets, afterRecovery + 1);
    h.close();
  });

  testWidgets('the poll GET is single-attempt (no retry on a 503)',
      (tester) async {
    final h = _harness();
    h.server.failNextGetsWith.addAll([503, 503, 503]);
    await h.enqueue();

    await tester.pump(_interval);
    // The standard policy would retry a 503 immediately (test delay is 0).
    expect(h.server.getRequests, hasLength(1));
    h.close();
  });

  testWidgets('does not poll while offline; refreshAll resumes once online',
      (tester) async {
    final h = _harness(offline: true);
    await h.enqueue();

    await tester.pump(_interval * 10);
    await h.notifier.refreshAll();
    await tester.pump(_interval * 10);
    expect(h.server.getRequests, isEmpty);

    h.offline.set(false);
    h.server.setStatus(1, 'running');
    await h.notifier.refreshAll();
    expect(h.server.activeSetGets, 1);
    expect(h.jobs.single.isRunning, isTrue);
    await tester.pump(_interval);
    expect(h.server.activeSetGets, 2, reason: 'polling resumed');
    h.close();
  });

  testWidgets('going offline while a poll is in flight stops the poll loop',
      (tester) async {
    final h = _harness();
    final timers = _TimerTracker();
    await timers.run(h.enqueue);
    h.server.holdGets = Completer<void>();
    await tester.pump(_interval); // poll fires and is now in flight
    expect(h.server.activeSetGets, 1);

    // Flip offline WHILE the request is outstanding, then let it land.
    h.offline.set(true);
    h.server.setStatus(1, 'running');
    h.server.holdGets!.complete();
    h.server.holdGets = null;
    await tester.pump();
    expect(h.jobs.single.isRunning, isTrue,
        reason: 'the in-flight response is still applied');

    await tester.pump(_interval * 10);
    expect(h.server.getRequests, hasLength(1),
        reason: 'no poll was sent after going offline');
    expect(timers.pending, 0, reason: 'the loop stopped, not just idled');
    h.close();
  });

  testWidgets('no poll, timer or state change after dispose', (tester) async {
    final h = _harness();
    await h.enqueue();
    h.server.holdGets = Completer<void>();
    await tester.pump(_interval); // poll fires and is now in flight
    expect(h.server.getRequests, hasLength(1));

    h.disposeContainer();
    h.server.setStatus(1, 'done');
    h.server.holdGets!.complete();
    await tester.pump(_interval * 10);

    expect(h.server.getRequests, hasLength(1));
    expect(h.sync.syncFreshCalls, 0);
    expect(h.printed, isEmpty, reason: 'no use-after-dispose error was caught');
    h.close();
  });

  testWidgets('a Done transition fires one fresh track sync', (tester) async {
    final server = _FakeJobsServer()
      ..put(_jobJson(jobId: 1, uuidId: 'a', status: 'running'))
      ..put(_jobJson(jobId: 2, uuidId: 'b', status: 'running'))
      ..put(_jobJson(jobId: 3, uuidId: 'c', status: 'running'));
    final h = _harness(server: server);
    await h.notifier.refreshAll();
    expect(h.jobs.where((j) => j.isRunning), hasLength(3));
    expect(h.sync.syncFreshCalls, 0);

    // Two finish in the same poll window, one fails.
    server
      ..setStatus(1, 'done')
      ..setStatus(2, 'done')
      ..setStatus(3, 'failed');
    await tester.pump(_interval);
    expect(h.jobs.where((j) => j.isDone), hasLength(2));
    expect(h.sync.syncFreshCalls, 1);

    await tester.pump(_interval * 5);
    expect(h.sync.syncFreshCalls, 1);
    h.close();
  });

  testWidgets('a failed or cancelled transition does not sync', (tester) async {
    final h = _harness();
    await h.enqueue();
    h.server.jobs[1] = _jobJson(status: 'failed', errorText: 'nope');
    await tester.pump(_interval);
    expect(h.jobs.single.status, const ConversionFailed(message: 'nope'));
    expect(h.sync.syncFreshCalls, 0);
    h.close();
  });

  testWidgets('finds the active job of a track with >50 historical jobs',
      (tester) async {
    final server = _FakeJobsServer();
    for (var id = 1; id <= 60; id++) {
      server.put(_jobJson(jobId: id, status: 'done'));
    }
    server.put(_jobJson(jobId: 61, status: 'running'));
    final h = _harness(server: server);

    await h.notifier.refreshAll();
    expect(h.jobs.map((j) => j.jobId), [61]);
    expect(h.jobs.single.isRunning, isTrue);

    // When it finishes it leaves the active set; its final state is still
    // found exactly despite the long history.
    server.setStatus(61, 'done');
    await tester.pump(_interval);
    expect(h.jobs.single.isDone, isTrue);
    final settle = h.server.getRequests.last.queryParameters;
    expect(settle['uuid_id'], 'abc');
    expect(settle['cursor'], '60');
    expect(settle['limit'], '1');
    h.close();
  });

  testWidgets('follows nextCursor across a full active-set page',
      (tester) async {
    ConversionJobsNotifier.activePageSize = 2;
    final server = _FakeJobsServer();
    for (var id = 1; id <= 5; id++) {
      server.put(_jobJson(jobId: id, uuidId: 'u$id', status: 'queued'));
    }
    final h = _harness(server: server);

    await h.notifier.refreshAll();
    expect(h.jobs.map((j) => j.jobId), [1, 2, 3, 4, 5]);
    expect(server.activeSetGets, 3);
    h.close();
  });

  testWidgets('refreshAll makes one active-set call and settles a job that '
      'finished while offline', (tester) async {
    final h = _harness();
    await h.enqueue(); // job 1, tracked as queued
    h.server.put(_jobJson(jobId: 2, uuidId: 'other', status: 'running'));
    h.server.setStatus(1, 'done');

    await h.notifier.refreshAll();
    expect(h.server.activeSetGets, 1);
    expect(h.server.getRequests.first.queryParameters['status'],
        'queued,running');
    expect(h.jobs.firstWhere((j) => j.jobId == 1).isDone, isTrue);
    expect(h.jobs.firstWhere((j) => j.jobId == 2).isRunning, isTrue);
    h.close();
  });

  testWidgets('refreshAll never throws on a server error', (tester) async {
    final h = _harness();
    h.server.failNextGetsWith.add(500);
    await h.notifier.refreshAll();
    expect(h.server.activeSetGets, 1, reason: 'the poll really ran and failed');
    expect(h.printed.join(), contains('poll failed'));
    expect(h.jobs, isEmpty);
    h.close();
  });

  testWidgets(
      'a failed discovery poll (no locally known job) retries with backoff '
      'until it succeeds', (tester) async {
    final server = _FakeJobsServer()
      ..put(_jobJson(jobId: 7, uuidId: 'x', status: 'running'));
    final h = _harness(server: server);
    server.failNextGetsWith.addAll([503, 503]);

    await h.notifier.refreshAll(); // t=0: fails (-> retry in 2s)
    expect(server.activeSetGets, 1);
    expect(h.jobs, isEmpty);

    await tester.pump(const Duration(milliseconds: 1900));
    expect(server.activeSetGets, 1, reason: 'backed off to 2s');
    await tester.pump(const Duration(milliseconds: 100)); // t=2s: fails (-> 4s)
    expect(server.activeSetGets, 2);
    await tester.pump(const Duration(seconds: 4)); // t=6s: succeeds
    expect(server.activeSetGets, 3);
    expect(h.jobs.single.jobId, 7);
    expect(h.jobs.single.isRunning, isTrue);

    // Discovered an active job -> normal polling continues from here.
    await tester.pump(_interval);
    expect(server.activeSetGets, 4);
    h.close();
  });

  testWidgets('a discovery retry that finds nothing stops polling',
      (tester) async {
    final h = _harness();
    h.server.failNextGetsWith.add(500);
    await h.notifier.refreshAll(); // fails
    await tester.pump(_interval * 2); // retry succeeds: nothing active
    expect(h.server.activeSetGets, 2);

    await tester.pump(_interval * 30);
    expect(h.server.activeSetGets, 2, reason: 'discovery satisfied');
    h.close();
  });

  testWidgets(
      'cold start with no server configured makes no request and does not '
      'trip offline mode', (tester) async {
    final h = _harness();
    ApiClient.initForTest('', h.server.client); // first install / Disconnect
    var networkFailures = 0;
    void onFailure() => networkFailures++;
    ApiClient.addNetworkFailureListener(onFailure);
    addTearDown(() => ApiClient.removeNetworkFailureListener(onFailure));
    final timers = _TimerTracker();

    await timers.run(h.notifier.refreshAll);
    await tester.pump(_interval * 30);

    expect(h.server.getRequests, isEmpty);
    expect(networkFailures, 0);
    expect(h.container.read(offlineModeProvider), isFalse);
    expect(h.printed, isEmpty, reason: 'no failed poll was even attempted');
    expect(timers.pending, 0);
    h.close();
  });

  testWidgets('a tracked job that vanished server-side is dropped',
      (tester) async {
    final h = _harness();
    await h.enqueue();
    h.server.jobs.remove(1); // pruned server-side

    await tester.pump(_interval);
    final settle = h.server.getRequests.last.queryParameters;
    expect(settle['uuid_id'], 'abc', reason: 'the settle lookup ran');
    expect(settle['cursor'], '0');
    expect(h.jobs, isEmpty, reason: 'dropped, not polled forever');

    final gets = h.server.getRequests.length;
    await tester.pump(_interval * 10);
    expect(h.server.getRequests.length, gets);
    h.close();
  });

  testWidgets(
      'an enqueue landing during an in-flight poll is kept and polled once '
      'per interval', (tester) async {
    final server = _FakeJobsServer()
      ..put(_jobJson(jobId: 1, uuidId: 'a', status: 'running'));
    final h = _harness(server: server);
    final timers = _TimerTracker();
    await timers.run(h.notifier.refreshAll);
    expect(h.jobs.single.jobId, 1);

    // The next poll's active-set response is computed now -- before job 2
    // exists -- and held on the wire.
    server
      ..snapshotBeforeHold = true
      ..holdGets = Completer<void>();
    await tester.pump(_interval);
    expect(server.activeSetGets, 2);

    server.nextPostResponse = _jobJson(jobId: 2, uuidId: 'abc');
    await timers.run(h.enqueue); // POST isn't held
    expect(h.jobs.map((j) => j.jobId), [1, 2]);

    server.holdGets!.complete();
    server
      ..holdGets = null
      ..snapshotBeforeHold = false;
    await tester.pump();

    expect(h.jobs.map((j) => j.jobId), [1, 2],
        reason: 'the stale active set (without job 2) must not drop it');
    expect(h.jobs.firstWhere((j) => j.jobId == 2).isQueued, isTrue);
    expect(timers.pending, 1, reason: 'one poll loop, not two');

    final before = server.activeSetGets;
    await tester.pump(_interval);
    expect(server.activeSetGets, before + 1);
    await tester.pump(_interval);
    expect(server.activeSetGets, before + 2);
    h.close();
  });

  testWidgets(
      'refreshAll + enqueue + recovery firing together leave exactly one '
      'pending poll timer', (tester) async {
    final server = _FakeJobsServer()
      ..put(_jobJson(jobId: 1, uuidId: 'a', status: 'running'));
    final h = _harness(server: server);
    final timers = _TimerTracker();
    await timers.run(h.notifier.refreshAll);
    expect(timers.pending, 1);

    final conversionRecovery = h.container
        .read(recoverablesProvider)
        .where((r) => r.recoveryPriority == RecoveryPriority.resumeConversions)
        .single;
    server.nextPostResponse = _jobJson(jobId: 2, uuidId: 'abc');
    await timers.run(
      () => Future.wait([
        h.notifier.refreshAll(),
        h.enqueue(),
        conversionRecovery.recover(RecoveryTrigger.networkRecovered),
      ]),
    );
    await tester.pump();

    expect(h.jobs.map((j) => j.jobId), [1, 2]);
    expect(timers.pending, 1);

    final before = server.activeSetGets;
    await tester.pump(_interval);
    expect(server.activeSetGets, before + 1, reason: 'one poll per interval');
    expect(timers.pending, 1);
    h.close();
  });

  testWidgets('a cancel racing an in-flight poll stays Cancelled',
      (tester) async {
    final h = _harness();
    final job = await h.enqueue();
    h.server.setStatus(1, 'running');
    h.server.holdGets = Completer<void>();
    await tester.pump(_interval); // poll in flight

    await h.notifier.cancel(job.jobId);
    expect(h.jobs.single.isCancelled, isTrue);

    // The in-flight response was computed while the job was still running.
    h.server.setStatus(1, 'running');
    h.server.holdGets!.complete();
    h.server.holdGets = null;
    await tester.pump();
    expect(h.jobs.single.isCancelled, isTrue);

    final gets = h.server.getRequests.length;
    await tester.pump(_interval * 5);
    expect(h.server.getRequests.length, gets, reason: 'nothing active');
    h.close();
  });

  testWidgets('a poll returning identical data does not notify listeners',
      (tester) async {
    final h = _harness();
    h.server.nextPostResponse = _jobJson(status: 'running');
    await h.enqueue();
    var notifications = 0;
    h.container.listen(conversionJobsProvider, (_, _) => notifications++);

    await tester.pump(_interval * 3);
    expect(h.server.activeSetGets, 3);
    expect(notifications, 0);

    h.server.setStatus(1, 'done');
    await tester.pump(_interval);
    expect(notifications, 1);
    h.close();
  });

  testWidgets('cancel marks the job cancelled locally when the backend confirms',
      (tester) async {
    final h = _harness();
    final job = await h.enqueue();
    await h.notifier.cancel(job.jobId);

    expect(h.jobs.single.isCancelled, isTrue);
    h.close();
  });

  testWidgets(
      'cancel leaves the job untouched when the backend reports cancelled: false',
      (tester) async {
    final h = _harness();
    final job = await h.enqueue();
    h.server.setStatus(1, 'done'); // already terminal server-side
    await h.notifier.cancel(job.jobId);

    expect(h.jobs.single.isQueued, isTrue);
    h.close();
  });
}
