// Phase M §7.2 "No secrets in logs" (M-U19): send() logs the method and the
// path, never the query (a later piece puts the media token in a query).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('send() logs method and path without the query', () async {
    final api = testApiClient(
      'http://srv:1',
      MockClient((_) async => http.Response('ok', 200)),
    );
    final lines = <String>[];
    api.setLogSinkForTest(lines.add);

    final response = await api.send(
      () => http.Request(
        'GET',
        Uri.parse('http://srv:1/tracks/abc/stream?quality=256&secret=s3'),
      ),
    );
    await response.stream.drain<void>();

    final streamed = lines.where((l) => l.contains('(streamed)')).toList();
    expect(streamed, ['200 (streamed) GET /tracks/abc/stream']);
    expect(lines.where((l) => l.contains('secret') || l.contains('quality')),
        isEmpty);
  });

  // U16-FE-API-B-06: a server address typed with a user name and password
  // in it must never reach the log; the JSON requests log the path only.
  test('a JSON request logs the path, never the address or its user info',
      () async {
    final api = testApiClient(
      'http://user:pa55word@srv:1',
      MockClient((_) async => http.Response('{}', 200,
          headers: {'content-type': 'application/json'})),
    );
    final lines = <String>[];
    api.setLogSinkForTest(lines.add);

    await api.getJson(['app', 'info'], policy: RetryPolicy.noRetry);

    expect(lines, isNotEmpty);
    expect(lines.where((l) => l.contains('pa55word') || l.contains('user:')),
        isEmpty);
    expect(lines.where((l) => l.contains('srv')), isEmpty,
        reason: 'the path only, as the streamed path logs it');
    expect(lines, contains(startsWith('GET /app/info')));
  });
}
