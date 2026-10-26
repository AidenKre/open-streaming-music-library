import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/jobs_api.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

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
  group('JobsApi.postConversionJob', () {
    test('POSTs the expected body to /jobs', () async {
      Map<String, dynamic>? capturedBody;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return Response(jsonEncode(_jobJson()), 200);
        }),
      );

      final job = await JobsApi().postConversionJob(
        uuidId: 'abc',
        targetCodec: 'aac',
        targetBitrateKbps: 192,
        baseRevision: 5,
      );

      expect(capturedBody, {
        'type': 'conversion',
        'uuid_id': 'abc',
        'params': {'target_codec': 'aac', 'target_bitrate_kbps': 192},
        'base_revision': 5,
      });
      expect(job.jobId, 1);
      expect(job.isQueued, isTrue);
    });

    test('sends a null target_bitrate_kbps for lossless targets', () async {
      Map<String, dynamic>? capturedBody;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return Response(jsonEncode(_jobJson()), 200);
        }),
      );

      await JobsApi().postConversionJob(
        uuidId: 'abc',
        targetCodec: 'flac',
        targetBitrateKbps: null,
        baseRevision: 5,
      );

      expect(capturedBody?['params'], {
        'target_codec': 'flac',
        'target_bitrate_kbps': null,
      });
    });

    test('throws ApiException on 409 revision conflict', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => Response(
            jsonEncode({
              'detail': {'error': 'revision_conflict', 'current_revision': 9},
            }),
            409,
          ),
        ),
      );

      expect(
        () => JobsApi().postConversionJob(
          uuidId: 'abc',
          targetCodec: 'aac',
          targetBitrateKbps: 192,
          baseRevision: 5,
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });
  });

  group('JobsApi.getJobs', () {
    test('parses the data list into ConversionJobs', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => Response(
            jsonEncode({
              'data': [_jobJson(jobId: 1), _jobJson(jobId: 2, status: 'done')],
              'nextCursor': null,
            }),
            200,
          ),
        ),
      );

      final jobs = await JobsApi().getJobs();

      expect(jobs.map((j) => j.jobId), [1, 2]);
      expect(jobs[1].isDone, isTrue);
    });

    test('passes uuid_id/status/cursor/limit as query params', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(jsonEncode({'data': [], 'nextCursor': null}), 200);
        }),
      );

      await JobsApi().getJobs(
        uuidId: 'abc', status: 'queued', cursor: 7, limit: 10,
      );

      expect(captured?.queryParameters['uuid_id'], 'abc');
      expect(captured?.queryParameters['status'], 'queued');
      expect(captured?.queryParameters['cursor'], '7');
      expect(captured?.queryParameters['limit'], '10');
    });

    test('omits optional query params when not given', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(jsonEncode({'data': [], 'nextCursor': null}), 200);
        }),
      );

      await JobsApi().getJobs();

      expect(captured?.queryParameters.containsKey('uuid_id'), isFalse);
      expect(captured?.queryParameters.containsKey('status'), isFalse);
      expect(captured?.queryParameters.containsKey('cursor'), isFalse);
    });

    test('getJobsPage returns nextCursor and sends a comma status list',
        () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(
            jsonEncode({'data': [_jobJson(jobId: 3)], 'nextCursor': 3}),
            200,
          );
        }),
      );

      final page = await JobsApi().getJobsPage(status: 'queued,running');

      expect(captured?.queryParameters['status'], 'queued,running');
      expect(page.jobs.single.jobId, 3);
      expect(page.nextCursor, 3);
    });

    test('retry: false makes a single attempt on a retryable status',
        () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('unavailable', 503);
        }),
      );

      await expectLater(
        JobsApi().getJobs(retry: false),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
    });
  });

  group('JobsApi.cancelJob', () {
    test('sends DELETE /jobs/{id} and returns cancelled flag', () async {
      String? method;
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          method = req.method;
          captured = req.url;
          return Response(jsonEncode({'cancelled': true}), 200);
        }),
      );

      final cancelled = await JobsApi().cancelJob(42);

      expect(method, 'DELETE');
      expect(captured?.pathSegments, ['jobs', '42']);
      expect(cancelled, isTrue);
    });
  });
}
