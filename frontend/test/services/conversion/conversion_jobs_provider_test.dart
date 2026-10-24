import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';

Map<String, dynamic> _jobJson({
  int jobId = 1,
  String uuidId = 'abc',
  String status = 'queued',
}) => {
  'job_id': jobId,
  'uuid_id': uuidId,
  'target_codec': 'aac',
  'target_container': 'm4a',
  'target_bitrate': 192,
  'status': status,
  'error_text': null,
  'created_at': 1000,
  'updated_at': 1000,
};

void main() {
  setUp(() {
    ConversionJobsNotifier.pollInterval = const Duration(milliseconds: 10);
  });

  tearDown(() {
    ConversionJobsNotifier.pollInterval = const Duration(seconds: 3);
  });

  test('starts with an empty job list', () {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{}', 200)),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(conversionJobsProvider), isEmpty);
  });

  test('enqueue adds the new job to state', () async {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response(jsonEncode(_jobJson()), 200)),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversionJobsProvider.notifier);

    final job = await notifier.enqueue(
      uuidId: 'abc', targetCodec: 'aac', targetBitrateKbps: 192, baseRevision: 1,
    );

    expect(job.jobId, 1);
    expect(container.read(conversionJobsProvider), [job]);
  });

  test('enqueue starts polling, which picks up the status transition', () async {
    var pollCount = 0;
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(jsonEncode(_jobJson(status: 'queued')), 200);
        }
        pollCount++;
        final status = pollCount < 2 ? 'running' : 'done';
        return http.Response(
          jsonEncode({'data': [_jobJson(status: status)], 'nextCursor': null}),
          200,
        );
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversionJobsProvider.notifier);

    await notifier.enqueue(
      uuidId: 'abc', targetCodec: 'aac', targetBitrateKbps: 192, baseRevision: 1,
    );

    await _waitFor(() => container.read(conversionJobsProvider).single.isDone);
    expect(container.read(conversionJobsProvider).single.isDone, isTrue);
  });

  test('polling stops once the job reaches a terminal state', () async {
    var getCalls = 0;
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(jsonEncode(_jobJson(status: 'queued')), 200);
        }
        getCalls++;
        return http.Response(
          jsonEncode({'data': [_jobJson(status: 'done')], 'nextCursor': null}),
          200,
        );
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversionJobsProvider.notifier);

    await notifier.enqueue(
      uuidId: 'abc', targetCodec: 'aac', targetBitrateKbps: 192, baseRevision: 1,
    );
    await _waitFor(() => container.read(conversionJobsProvider).single.isDone);

    final callsAtDone = getCalls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(getCalls, callsAtDone, reason: 'no further polling once terminal');
  });

  test('cancel marks the job cancelled locally when the backend confirms', () async {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(jsonEncode(_jobJson(status: 'queued')), 200);
        }
        if (req.method == 'DELETE') {
          return http.Response(jsonEncode({'cancelled': true}), 200);
        }
        return http.Response(jsonEncode({'data': [], 'nextCursor': null}), 200);
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversionJobsProvider.notifier);

    final job = await notifier.enqueue(
      uuidId: 'abc', targetCodec: 'aac', targetBitrateKbps: 192, baseRevision: 1,
    );
    await notifier.cancel(job.jobId);

    expect(container.read(conversionJobsProvider).single.isCancelled, isTrue);
  });

  test('cancel leaves the job untouched when the backend reports cancelled: false', () async {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(jsonEncode(_jobJson(status: 'queued')), 200);
        }
        if (req.method == 'DELETE') {
          return http.Response(jsonEncode({'cancelled': false}), 200);
        }
        return http.Response(jsonEncode({'data': [], 'nextCursor': null}), 200);
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversionJobsProvider.notifier);

    final job = await notifier.enqueue(
      uuidId: 'abc', targetCodec: 'aac', targetBitrateKbps: 192, baseRevision: 1,
    );
    await notifier.cancel(job.jobId);

    expect(container.read(conversionJobsProvider).single.isQueued, isTrue);
  });

  test('refreshAll discovers jobs from a previous session and resumes polling', () async {
    var pollCount = 0;
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async {
        final status = req.url.queryParameters['status'];
        // The initial refreshAll discovery calls, filtered by status.
        if (status == 'queued') {
          return http.Response(jsonEncode({'data': [], 'nextCursor': null}), 200);
        }
        if (status == 'running') {
          return http.Response(
            jsonEncode({'data': [_jobJson(status: 'running')], 'nextCursor': null}),
            200,
          );
        }
        // Subsequent polling, filtered by uuid_id instead.
        pollCount++;
        final jobStatus = pollCount < 2 ? 'running' : 'done';
        return http.Response(
          jsonEncode({'data': [_jobJson(status: jobStatus)], 'nextCursor': null}),
          200,
        );
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversionJobsProvider.notifier);

    await notifier.refreshAll();

    expect(container.read(conversionJobsProvider), isNotEmpty);
    await _waitFor(() => container.read(conversionJobsProvider).single.isDone);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition was not met in time');
}
