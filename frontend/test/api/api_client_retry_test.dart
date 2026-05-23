import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

void main() {
  group('ApiClient retry — retryable HTTP status codes', () {
    for (final code in [408, 429, 502, 503, 504]) {
      test('retries on $code and succeeds on third attempt', () async {
        var calls = 0;
        ApiClient.initForTest(
          'http://localhost:8000',
          MockClient((req) async {
            calls++;
            if (calls < 3) return Response('try again', code);
            return Response(jsonEncode({'ok': true}), 200);
          }),
        );

        final result = await ApiClient.instance.getJson(['tracks']);

        expect(calls, 3);
        expect(result['ok'], true);
      });
    }
  });

  group('ApiClient retry — non-retryable HTTP status codes', () {
    for (final code in [400, 404, 416, 422, 500, 501]) {
      test('does NOT retry on $code; throws ApiException immediately', () async {
        var calls = 0;
        ApiClient.initForTest(
          'http://localhost:8000',
          MockClient((req) async {
            calls++;
            return Response('nope', code);
          }),
        );

        await expectLater(
          ApiClient.instance.getJson(['tracks']),
          throwsA(isA<ApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            code,
          )),
        );
        expect(calls, 1, reason: 'should not retry non-retryable status $code');
      });
    }
  });

  group('ApiClient retry — retryable network exceptions', () {
    test('retries on SocketException and succeeds', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 3) throw const SocketException('connection refused');
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );

      final result = await ApiClient.instance.getJson(['tracks']);

      expect(calls, 3);
      expect(result['ok'], true);
    });

    test('retries on http.ClientException and succeeds', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 2) throw ClientException('stream closed early');
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );

      final result = await ApiClient.instance.getJson(['tracks']);

      expect(calls, 2);
      expect(result['ok'], true);
    });

    test('exhausts retries on persistent SocketException; throws NetworkException with attemptsMade=3', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          throw const SocketException('no route to host');
        }),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<SocketException>())),
      );
      expect(calls, 3);
    });

    test('exhausts retries on persistent retryable status; throws ApiException with that code', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('upstream gone', 503);
        }),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', 'upstream gone')),
      );
      expect(calls, 3);
    });
  });

  group('ApiClient retry — Retry-After header', () {
    test('honors Retry-After: <seconds> on 503', () async {
      var calls = 0;
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) {
            return Response('try later', 503, headers: {'retry-after': '2'});
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      final result = await ApiClient.instance.getJson(['tracks']);

      expect(result['ok'], true);
      expect(calls, 2);
      expect(delays, hasLength(1));
      expect(delays.single, const Duration(seconds: 2));
    });

    test('honors Retry-After: <HTTP-date>', () async {
      var calls = 0;
      final delays = <Duration>[];
      final futureDate = DateTime.now().toUtc().add(const Duration(seconds: 3));
      // HTTP-date format: "EEE, dd MMM yyyy HH:mm:ss GMT"
      String fmt(DateTime d) {
        const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        String two(int n) => n.toString().padLeft(2, '0');
        return '${weekdays[d.weekday - 1]}, ${two(d.day)} ${months[d.month - 1]} '
            '${d.year} ${two(d.hour)}:${two(d.minute)}:${two(d.second)} GMT';
      }

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) {
            return Response('try later', 503, headers: {'retry-after': fmt(futureDate)});
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      final result = await ApiClient.instance.getJson(['tracks']);

      expect(result['ok'], true);
      expect(delays, hasLength(1));
      // Allow a small tolerance — the date math is computed at request time.
      expect(delays.single.inMilliseconds, greaterThan(1500));
      expect(delays.single.inMilliseconds, lessThan(4000));
    });

    test('clamps Retry-After to 10 seconds', () async {
      var calls = 0;
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) {
            return Response('try later', 503, headers: {'retry-after': '3600'});
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      await ApiClient.instance.getJson(['tracks']);

      expect(delays.single, const Duration(seconds: 10));
    });

    test('ignores malformed Retry-After and falls back to backoff', () async {
      var calls = 0;
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) {
            return Response('try later', 503, headers: {'retry-after': 'not-a-date'});
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      await ApiClient.instance.getJson(['tracks']);

      // _random is seeded with Random(0) by initForTest, and the
      // attempt-1 window is 250ms → nextInt(251) returns 55 deterministically.
      // This asserts the exact backoff math (2^(n-1) window), not just
      // "within the window" which would pass for the wrong formula.
      expect(delays.single, const Duration(milliseconds: 55));
    });

    test('exponential backoff windows double across attempts (deterministic seed)',
        () async {
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('busy', 503)),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 503)),
      );

      // With Random(0):
      //   attempt1→2: nextInt(251) = 55  (window = 250ms * 2^0)
      //   attempt2→3: nextInt(501) = 233 (window = 250ms * 2^1)
      // This pins the 2^(n-1) formula. If someone changes it to 2^n the
      // first window becomes 501 and the values shift.
      expect(delays, [
        const Duration(milliseconds: 55),
        const Duration(milliseconds: 233),
      ]);
    });
  });

  group('ApiClient retry — per-attempt timeout', () {
    test('hung request hits per-attempt timeout, retries, then throws NetworkException', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          // Block 5x the configured per-attempt timeout. The .timeout() in
          // _withRetry must fire to drive retries; if it didn't, this test
          // would take 1.5s (3 × 500ms) instead of ~300ms and we'd notice.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return Response('never', 200);
        }),
      );
      // Shrink the per-attempt timeout to 100ms so this test runs in ms,
      // not seconds. The contract under test is unchanged: a per-attempt
      // hang triggers TimeoutException → retry → eventual NetworkException.
      ApiClient.instance.setPerAttemptTimeoutForTest(
        const Duration(milliseconds: 100),
      );

      final sw = Stopwatch()..start();
      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<TimeoutException>())),
      );
      sw.stop();
      expect(calls, 3);
      // Three 100ms timeouts (sequential because of await) + no-op delay
      // between attempts ≈ 300ms. Generous upper bound for CI variance.
      // Crucially this also proves the timeout VALUE is honored — if the
      // injection didn't take effect we'd take ~30s and this would fail.
      expect(sw.elapsed.inMilliseconds, lessThan(2000));
    });

    test('per-attempt timeout fires INDEPENDENTLY of the configured value', () async {
      // Reinforces the previous test by using a different timeout value
      // and asserting elapsed time scales accordingly. Catches a regression
      // where the timeout becomes hardcoded.
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return Response('never', 200);
        }),
      );
      ApiClient.instance.setPerAttemptTimeoutForTest(
        const Duration(milliseconds: 50),
      );

      final sw = Stopwatch()..start();
      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );
      sw.stop();
      // 3 × 50ms = 150ms. Loose ceiling for CI.
      expect(sw.elapsed.inMilliseconds, lessThan(1500));
    });
  });

  group('ApiClient retry — applies to all request methods', () {
    test('putJson(retry: true) retries on 503', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 2) return Response('try again', 503);
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );

      final result = await ApiClient.instance.putJson(
        ['settings', 'quality'],
        body: {'quality': 'high'},
        retry: true,
      );

      expect(calls, 2);
      expect(result['ok'], true);
    });

    test('postJson(retry: true) retries on 502', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 2) return Response('upstream', 502);
          return Response(jsonEncode({'accepted': true}), 200);
        }),
      );

      final result = await ApiClient.instance.postJson(
        ['tracks', 'warm'],
        body: {'track_uuids': []},
        retry: true,
      );

      expect(calls, 2);
      expect(result['accepted'], true);
    });

    test('getBytes retries on 504 and returns bytes on success', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 2) return Response('timeout', 504);
          return Response.bytes([1, 2, 3, 4], 200);
        }),
      );

      final bytes = await ApiClient.instance.getBytes(['cover_art', '42']);

      expect(calls, 2);
      expect(bytes, [1, 2, 3, 4]);
    });

    test('getBytes throws ApiException on non-retryable 404', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('not found', 404);
        }),
      );

      await expectLater(
        ApiClient.instance.getBytes(['cover_art', '99']),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
      expect(calls, 1);
    });
  });

  group('ApiClient retry — send (streamed)', () {
    test('send retries on initial 503 and returns StreamedResponse on success', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient.streaming((req, body) async {
          calls++;
          if (calls < 2) {
            return StreamedResponse(
              Stream.value(utf8.encode('busy')),
              503,
            );
          }
          return StreamedResponse(
            Stream.fromIterable([
              [1, 2, 3],
              [4, 5, 6],
            ]),
            200,
            headers: {'content-type': 'audio/mp4'},
          );
        }),
      );

      final response = await ApiClient.instance.send(
        () => Request('GET', Uri.parse('http://localhost:8000/tracks/x/stream')),
      );

      expect(calls, 2);
      expect(response.statusCode, 200);
      final collected = <int>[];
      await for (final chunk in response.stream) {
        collected.addAll(chunk);
      }
      expect(collected, [1, 2, 3, 4, 5, 6]);
    });

    test('send invokes factory once per attempt (BaseRequest is one-shot)', () async {
      var factoryCalls = 0;
      var serverCalls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient.streaming((req, body) async {
          serverCalls++;
          if (serverCalls < 3) {
            return StreamedResponse(
              Stream.value(utf8.encode('busy')),
              503,
            );
          }
          return StreamedResponse(Stream.empty(), 200);
        }),
      );

      await ApiClient.instance.send(() {
        factoryCalls++;
        return Request('GET', Uri.parse('http://localhost:8000/tracks/x/stream'));
      });

      expect(factoryCalls, 3);
      expect(serverCalls, 3);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // Gap-closing tests added after the post-retry-system review.
  // Each group references the gap ID from the review (G1, G2, ...).
  // ─────────────────────────────────────────────────────────────────────

  group('ApiClient retry — G1: ClientException exhaustion', () {
    test('persistent ClientException exhausts to NetworkException with cause', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          throw ClientException('connection reset');
        }),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<ClientException>())),
      );
    });
  });

  group('ApiClient retry — G2: mixed exception sequence', () {
    test('SocketException then 503 exhausts to ApiException(503), not NetworkException', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) throw const SocketException('first');
          return Response('upstream', 503);
        }),
      );

      // Final exhausting failure is HTTP, so ApiException wins.
      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', 'upstream')),
      );
      expect(calls, 3);
    });

    test('503 then SocketException exhausts to NetworkException, NOT ApiException', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) return Response('busy', 503);
          throw const SocketException('then network');
        }),
      );

      // Final exhausting failure is network, so NetworkException wins —
      // earlier 503 status is intentionally NOT preserved (single-cause).
      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<SocketException>())),
      );
      expect(calls, 3);
    });
  });

  group('ApiClient retry — G3: Retry-After on later attempts', () {
    test('Retry-After is honored when set on attempt 2 (not just attempt 1)', () async {
      var calls = 0;
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) return Response('busy', 503); // no header → backoff
          if (calls == 2) {
            return Response('still busy', 503,
                headers: {'retry-after': '4'}); // header on attempt 2
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      await ApiClient.instance.getJson(['tracks']);

      expect(calls, 3);
      expect(delays, hasLength(2));
      // Attempt 1→2: backoff (Random(0).nextInt(251) = 55ms)
      expect(delays[0], const Duration(milliseconds: 55));
      // Attempt 2→3: Retry-After header takes precedence over backoff
      expect(delays[1], const Duration(seconds: 4));
    });

    test('Retry-After on 502 is honored (broad RFC interpretation)', () async {
      var calls = 0;
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) {
            return Response('bad gateway', 502, headers: {'retry-after': '3'});
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      await ApiClient.instance.getJson(['tracks']);

      // Documents the contract: Retry-After is honored on ANY retryable
      // status, not just 429/503. Proxies emit it on 502/504 in practice.
      expect(delays.single, const Duration(seconds: 3));
    });
  });

  group('ApiClient retry — G4: header case sensitivity', () {
    test('canonical "Retry-After" (capitalized) header is honored', () async {
      var calls = 0;
      final delays = <Duration>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) {
            // Real servers send canonical case. The http package lowercases
            // headers in IOClient but Response() preserves what we pass —
            // this test proves our lookup tolerates both spellings.
            return Response('busy', 503, headers: {'Retry-After': '2'});
          }
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );
      ApiClient.instance.setDelayFnForTest((d) async {
        delays.add(d);
      });

      await ApiClient.instance.getJson(['tracks']);
      // http.Response normalizes header keys to lowercase, so our
      // `headers['retry-after']` lookup matches.
      expect(delays.single, const Duration(seconds: 2));
    });
  });

  group('ApiClient retry — G5: empty body preserved', () {
    test('exhausted 503 with empty body throws ApiException(503, "")', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('', 503)),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', '')),
      );
    });
  });

  group('ApiClient retry — G7: send() mid-stream failure is NOT retried', () {
    test('a 200 StreamedResponse whose stream errors mid-flight escapes raw to caller', () async {
      var factoryCalls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient.streaming((req, body) async {
          return StreamedResponse(
            Stream<List<int>>.error(const SocketException('mid-stream drop')),
            200,
          );
        }),
      );

      // The initial handshake (status 200) succeeds — retry boundary closes.
      // Stream errors AFTER that point are the caller's problem.
      final response = await ApiClient.instance.send(() {
        factoryCalls++;
        return Request('GET', Uri.parse('http://localhost:8000/tracks/x/stream'));
      });

      expect(response.statusCode, 200);
      // Factory invoked exactly once — no retries on mid-stream failure.
      expect(factoryCalls, 1);
      // Iterating the stream surfaces the original error, not a wrapped one.
      await expectLater(
        response.stream.toList(),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('ApiClient retry — G8: NetworkException exhaustion for ALL methods', () {
    test('putJson(retry: true): persistent SocketException → NetworkException', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );
      await expectLater(
        ApiClient.instance.putJson(
          ['settings', 'quality'],
          body: {'q': '320'},
          retry: true,
        ),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<SocketException>())),
      );
    });

    test('postJson(retry: true): persistent TimeoutException → NetworkException', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return Response('', 200);
        }),
      );
      ApiClient.instance.setPerAttemptTimeoutForTest(
        const Duration(milliseconds: 50),
      );
      await expectLater(
        ApiClient.instance.postJson(['tracks', 'warm'], body: {}, retry: true),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<TimeoutException>())),
      );
    });

    test('getBytes: persistent ClientException → NetworkException', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw ClientException('reset')),
      );
      await expectLater(
        ApiClient.instance.getBytes(['cover_art', '1']),
        throwsA(isA<NetworkException>()
            .having((e) => e.cause, 'cause', isA<ClientException>())),
      );
    });

    test('send: persistent SocketException → NetworkException', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient.streaming((req, body) async {
          throw const SocketException('down');
        }),
      );
      await expectLater(
        ApiClient.instance.send(
          () => Request('GET', Uri.parse('http://localhost:8000/tracks/x/stream')),
        ),
        throwsA(isA<NetworkException>()
            .having((e) => e.cause, 'cause', isA<SocketException>())),
      );
    });
  });

  group('ApiClient retry — G9: healthCheck on unreachable server', () {
    test('healthCheck returns unreachable HealthResult after retries exhausted', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('no route')),
      );

      final result = await ApiClient.instance.healthCheck();

      expect(result.status, HealthStatus.unreachable);
      expect(result.message, startsWith('Could not reach server:'));
    });

    test('healthCheck returns serverError HealthResult when backend is up but failing', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('boom', 500)),
      );

      final result = await ApiClient.instance.healthCheck();

      expect(result.status, HealthStatus.serverError);
      expect(result.message, 'Server error: 500');
    });
  });

  group('ApiClient retry — G10: ArgumentError is caught', () {
    test('ArgumentError from the transport layer is wrapped as NetworkException',
        () async {
      // In production, http's IOClient throws ArgumentError when baseUrl
      // is malformed (no scheme/host). MockClient doesn't validate URLs,
      // so we simulate the same error directly. The contract under test:
      // ArgumentError must not escape raw — it must surface as
      // NetworkException after retries exhaust.
      ApiClient.initForTest(
        '',
        MockClient((req) async {
          throw ArgumentError('No host specified in URI');
        }),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 3)
            .having((e) => e.cause, 'cause', isA<ArgumentError>())),
      );
    });

    test('transient ArgumentError followed by success recovers', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls == 1) throw ArgumentError('flaky');
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );

      final result = await ApiClient.instance.getJson(['tracks']);

      expect(calls, 2);
      expect(result['ok'], true);
    });
  });

  group('ApiClient retry — malformed JSON on 2xx', () {
    test('2xx with non-JSON body throws ApiException, not raw FormatException', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('this is not json {{{', 200)),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 200)
            .having((e) => e.message, 'message', contains('Malformed JSON'))),
      );
    });

    test('2xx with JSON array (wrong shape) throws ApiException', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('[1, 2, 3]', 200)),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 200)),
      );
    });
  });

  group('ApiClient — postJson/putJson default to no retry', () {
    test('postJson without retry makes exactly one attempt on 503', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('busy', 503);
        }),
      );

      await expectLater(
        ApiClient.instance.postJson(['tracks', 'warm'], body: {}),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
      expect(calls, 1, reason: 'default postJson must not retry');
    });

    test('putJson without retry makes exactly one attempt on SocketException',
        () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          throw const SocketException('down');
        }),
      );

      await expectLater(
        ApiClient.instance.putJson(
          ['settings', 'quality'],
          body: {'quality': 'high'},
        ),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 1)
            .having((e) => e.cause, 'cause', isA<SocketException>())),
      );
      expect(calls, 1, reason: 'default putJson must not retry');
    });

    test('postJson(retry: true) recovers from a transient SocketException',
        () async {
      // Covers the opt-in retry path for a transport-layer (non-HTTP) failure,
      // complementing the existing 502/503 status-code retry coverage.
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 2) throw const SocketException('flaky');
          return Response(jsonEncode({'accepted': true}), 200);
        }),
      );

      final result = await ApiClient.instance.postJson(
        ['tracks', 'warm'],
        body: {'track_uuids': []},
        retry: true,
      );

      expect(calls, 2);
      expect(result['accepted'], true);
    });
  });

  group('ApiClient — healthCheck does not flip global offline mode', () {
    tearDown(ApiClient.clearNetworkFailureListenersForTest);

    test('healthCheck transport failure does NOT invoke network-failure listeners', () async {
      var hookCalls = 0;
      ApiClient.addNetworkFailureListener(() => hookCalls++);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      final result = await ApiClient.instance.healthCheck();

      expect(result.status, HealthStatus.unreachable);
      expect(hookCalls, 0,
          reason: 'a health-check probe must not enter offline mode');
    });

    test('healthCheck(retry: false) transport failure does NOT invoke network-failure listeners',
        () async {
      var hookCalls = 0;
      ApiClient.addNetworkFailureListener(() => hookCalls++);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      await ApiClient.instance.healthCheck(retry: false);

      expect(hookCalls, 0);
    });

    test('a normal getJson transport failure DOES invoke network-failure listeners',
        () async {
      var hookCalls = 0;
      ApiClient.addNetworkFailureListener(() => hookCalls++);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );
      expect(hookCalls, 1,
          reason: 'normal requests still drive offline mode on failure');
    });
  });

  group('ApiClient.getBytes — retry / triggerOfflineHook opt-out', () {
    tearDown(ApiClient.clearNetworkFailureListenersForTest);

    test('getBytes(retry: false) makes exactly one attempt on a retryable 504', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('timeout', 504);
        }),
      );

      await expectLater(
        ApiClient.instance.getBytes(
          ['cover_art', '7'],
          retry: false,
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 504)),
      );
      expect(calls, 1, reason: 'retry: false must not retry');
    });

    test('getBytes(retry: false) makes exactly one attempt on a SocketException', () async {
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          throw const SocketException('down');
        }),
      );

      await expectLater(
        ApiClient.instance.getBytes(
          ['cover_art', '8'],
          retry: false,
        ),
        throwsA(isA<NetworkException>()
            .having((e) => e.attemptsMade, 'attemptsMade', 1)
            .having((e) => e.cause, 'cause', isA<SocketException>())),
      );
      expect(calls, 1);
    });

    test('getBytes(triggerOfflineHook: false) does NOT fire listeners on SocketException exhaustion',
        () async {
      var hookCalls = 0;
      ApiClient.addNetworkFailureListener(() => hookCalls++);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      await expectLater(
        ApiClient.instance.getBytes(
          ['cover_art', '9'],
          triggerOfflineHook: false,
        ),
        throwsA(isA<NetworkException>()),
      );
      expect(hookCalls, 0,
          reason: 'cover-art callers opt out of flipping offline mode');
    });

    test('getBytes(retry: false, triggerOfflineHook: false) on SocketException: one attempt, no listener fired',
        () async {
      var hookCalls = 0;
      var calls = 0;
      ApiClient.addNetworkFailureListener(() => hookCalls++);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          throw const SocketException('down');
        }),
      );

      await expectLater(
        ApiClient.instance.getBytes(
          ['cover_art', '10'],
          retry: false,
          triggerOfflineHook: false,
        ),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1);
      expect(hookCalls, 0);
    });
  });

  group('ApiClient.addNetworkFailureListener — multi-listener API', () {
    tearDown(ApiClient.clearNetworkFailureListenersForTest);

    test('two listeners both fire when a network failure exhausts retries', () async {
      var aCalls = 0;
      var bCalls = 0;
      ApiClient.addNetworkFailureListener(() => aCalls++);
      ApiClient.addNetworkFailureListener(() => bCalls++);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );

      expect(aCalls, 1);
      expect(bCalls, 1);
    });

    test('removing a listener stops it from firing; re-adding restores it', () async {
      var calls = 0;
      void listener() => calls++;

      ApiClient.addNetworkFailureListener(listener);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1);

      ApiClient.removeNetworkFailureListener(listener);
      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1, reason: 'removed listener must not fire');

      ApiClient.addNetworkFailureListener(listener);
      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 2, reason: 'listener re-added → fires again');
    });

    test('adding the same listener twice does NOT double-fire (Set semantics)', () async {
      var calls = 0;
      void listener() => calls++;

      ApiClient.addNetworkFailureListener(listener);
      ApiClient.addNetworkFailureListener(listener);
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => throw const SocketException('down')),
      );

      await expectLater(
        ApiClient.instance.getJson(['tracks']),
        throwsA(isA<NetworkException>()),
      );

      expect(calls, 1, reason: 'Set dedupes identical listener registrations');
    });
  });

  group('NetworkException', () {
    test('toString includes attempts and message', () {
      final e = NetworkException('host down', attemptsMade: 3);
      expect(e.toString(), 'NetworkException(3 attempts): host down');
    });
  });

  group('ApiClient — explicit RetryPolicy parameter', () {
    test('policy: RetryPolicy(maxAttempts: 5) drives 5 attempts end-to-end', () async {
      // Proves the new opt-in `policy` parameter actually overrides the
      // hardcoded 3-attempt default — i.e. RetryPolicy is wired through
      // _request<T> all the way to the retry loop. Five attempts each
      // returning a retryable 503; succeeds on attempt 5.
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 5) return Response('try again', 503);
          return Response(jsonEncode({'ok': true, 'calls': calls}), 200);
        }),
      );

      final result = await ApiClient.instance.getJson(
        ['tracks'],
        policy: const RetryPolicy(maxAttempts: 5),
      );

      expect(calls, 5);
      expect(result['ok'], true);
      expect(result['calls'], 5);
    });

    test('policy: RetryPolicy(maxAttempts: 5) drives 5 attempts before NetworkException on exhaustion', () async {
      // Same idea but on the transport-error path: the NetworkException's
      // attemptsMade must reflect the policy, not the legacy _maxAttempts=3.
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          throw const SocketException('persistently down');
        }),
      );

      await expectLater(
        ApiClient.instance.getJson(
          ['tracks'],
          policy: const RetryPolicy(maxAttempts: 5),
        ),
        throwsA(isA<NetworkException>().having(
          (e) => e.attemptsMade,
          'attemptsMade',
          5,
        )),
      );
      expect(calls, 5);
    });

    test('explicit policy on postJson overrides the legacy retry:false default', () async {
      // postJson defaults to noRetry, but passing an explicit policy with
      // maxAttempts > 1 wins. Confirms _resolvePolicy precedence.
      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          if (calls < 2) return Response('try again', 503);
          return Response(jsonEncode({'ok': true}), 200);
        }),
      );

      final result = await ApiClient.instance.postJson(
        ['warm'],
        body: const {'session': '1'},
        policy: const RetryPolicy(maxAttempts: 2),
      );

      expect(calls, 2);
      expect(result['ok'], true);
    });

    test('legacy triggerOfflineHook:false still suppresses listeners when explicit policy is provided', () async {
      // Combining `policy:` with `triggerOfflineHook: false` must keep the
      // suppression — the boolean wins on this single field via copyWith.
      var fired = 0;
      void listener() => fired++;
      ApiClient.addNetworkFailureListener(listener);
      addTearDown(() => ApiClient.removeNetworkFailureListener(listener));

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          throw const SocketException('down');
        }),
      );

      await expectLater(
        ApiClient.instance.getJson(
          ['tracks'],
          triggerOfflineHook: false,
          policy: const RetryPolicy(maxAttempts: 2),
        ),
        throwsA(isA<NetworkException>().having(
          (e) => e.attemptsMade,
          'attemptsMade',
          2,
        )),
      );
      expect(fired, 0,
          reason: 'triggerOfflineHook:false must override the policy default');
    });
  });
}
