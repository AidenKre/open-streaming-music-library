import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thrown when the retry helper exhausts attempts on a transport-level error
/// (socket dropped, DNS failure, timeout, low-level http.ClientException).
///
/// Distinct from [ApiException] so callers (and a future offline-mode
/// observer) can distinguish "backend unreachable" from "backend returned an
/// error response".
class NetworkException implements Exception {
  final String message;
  final Object? cause;
  final int attemptsMade;

  NetworkException(this.message, {this.cause, required this.attemptsMade});

  @override
  String toString() => 'NetworkException($attemptsMade attempts): $message';
}

typedef DelayFn = Future<void> Function(Duration);

/// Result of a health check. `unreachable` means the network call itself
/// failed (transport-level) — eligible for offline mode. `serverError` means
/// the server answered with a non-2xx (e.g. 500) or an unexpected body — the
/// server is up but misbehaving, so the user should see an inline error
/// rather than enter offline mode.
enum HealthStatus { ok, serverError, unreachable }

class HealthResult {
  final HealthStatus status;
  final String? message;
  const HealthResult(this.status, [this.message]);
  bool get isOk => status == HealthStatus.ok;
}

class ApiClient {
  static final ApiClient instance = ApiClient._();
  ApiClient._() : _http = http.Client(), baseUrl = '';

  /// Listeners invoked when a normal request exhausts retries on a
  /// transport-level failure. Static so they're reachable from the singleton
  /// without threading an extra dependency through every service. Probe
  /// calls opt out via `triggerOfflineHook: false` (see [healthCheck]).
  ///
  /// Multiple observers can register independently (e.g. offline-mode
  /// notifier + telemetry breadcrumbs) without clobbering each other. Using
  /// a Set means re-registering the same listener is a no-op.
  ///
  /// There is deliberately no success counterpart: a received HTTP response
  /// (even a 2xx) does not prove the backend is healthy enough to resume
  /// normal work. Offline mode is exited only by a passing health check.
  static final Set<void Function()> _networkFailureListeners = {};

  static void addNetworkFailureListener(void Function() listener) {
    _networkFailureListeners.add(listener);
  }

  static void removeNetworkFailureListener(void Function() listener) {
    _networkFailureListeners.remove(listener);
  }

  @visibleForTesting
  static void clearNetworkFailureListenersForTest() {
    _networkFailureListeners.clear();
  }

  static void _fireNetworkFailure() {
    // Snapshot to tolerate listeners that remove themselves during dispatch.
    for (final listener in _networkFailureListeners.toList()) {
      listener();
    }
  }

  String baseUrl;
  http.Client _http;

  // Retry configuration. Centralized so all five request methods share it.
  static const int _maxAttempts = 3;
  static const Duration _baseDelay = Duration(milliseconds: 250);
  static const Duration _maxRetryAfter = Duration(seconds: 10);
  static const Duration _defaultPerAttemptTimeout = Duration(seconds: 10);
  static const Set<int> _retryableStatusCodes = {408, 429, 502, 503, 504};

  // Test seams. Tests inject a no-op delay + short timeout to run in
  // milliseconds; production uses Future.delayed and a 10s per-attempt limit.
  DelayFn _delay = Future.delayed;
  math.Random _random = math.Random();
  Duration _perAttemptTimeout = _defaultPerAttemptTimeout;

  static void init(String url) {
    instance.baseUrl = url;
  }

  @visibleForTesting
  static void initForTest(String url, http.Client httpClient) {
    instance.baseUrl = url;
    instance._http = httpClient;
    instance._delay = (_) async {};
    instance._random = math.Random(0);
    instance._perAttemptTimeout = _defaultPerAttemptTimeout;
  }

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void setDelayFnForTest(DelayFn fn) {
    _delay = fn;
  }

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void setPerAttemptTimeoutForTest(Duration timeout) {
    _perAttemptTimeout = timeout;
  }

  Uri _buildUri(
    List<String> pathSegments, {
    Map<String, String>? query,
  }) {
    final baseUri = Uri.parse(baseUrl);
    final basePath = baseUri.pathSegments.where((s) => s.isNotEmpty).toList();
    return baseUri.replace(
      pathSegments: [...basePath, ...pathSegments],
      queryParameters: query?.isNotEmpty == true ? query : null,
    );
  }

  /// GET returning JSON. Retries transient failures by default; pass
  /// `retry: false` for a single-attempt call (used by health polling, which
  /// is its own retry loop).
  Future<Map<String, dynamic>> getJson(
    List<String> pathSegments, {
    Map<String, String>? query,
    Map<String, String>? headers,
    bool retry = true,
    bool triggerOfflineHook = true,
  }) async {
    final uri = _buildUri(pathSegments, query: query);
    Future<Map<String, dynamic>> attempt() async {
      final response = await _http.get(
        uri,
        headers: {'Accept': 'application/json', ...?headers},
      );
      developer.log(
        '${response.statusCode} ${response.body.length}B',
        name: 'ApiClient',
      );
      return _handleJsonResponse(response);
    }
    final label = 'GET $uri';
    return retry
        ? _withRetry<Map<String, dynamic>>(
            attempt,
            label: label,
            triggerOfflineHook: triggerOfflineHook,
          )
        : _withoutRetry<Map<String, dynamic>>(
            attempt,
            label: label,
            triggerOfflineHook: triggerOfflineHook,
          );
  }

  /// PUT with JSON body. Defaults to a **single attempt** — pass `retry: true`
  /// only when the endpoint is idempotent (setting the same value twice ends
  /// in the same state) or its duplicate execution is otherwise acceptable.
  /// See the note at [_runAttempt] for why retry is opt-in for mutations.
  Future<Map<String, dynamic>> putJson(
    List<String> pathSegments, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    bool retry = false,
  }) async {
    final uri = _buildUri(pathSegments);
    final encodedBody = body != null ? jsonEncode(body) : null;
    Future<Map<String, dynamic>> attempt() async {
      final response = await _http.put(
        uri,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          ...?headers,
        },
        body: encodedBody,
      );
      developer.log(
        '${response.statusCode} ${response.body.length}B',
        name: 'ApiClient',
      );
      return _handleJsonResponse(response);
    }
    final label = 'PUT $uri';
    return retry
        ? _withRetry<Map<String, dynamic>>(attempt, label: label)
        : _withoutRetry<Map<String, dynamic>>(attempt, label: label);
  }

  /// POST with JSON body. Defaults to a **single attempt** — pass `retry: true`
  /// only when the endpoint is idempotent or advisory (failures are
  /// acceptable; duplicate execution does no harm). See the note at
  /// [_runAttempt] for why retry is opt-in for mutations.
  Future<Map<String, dynamic>> postJson(
    List<String> pathSegments, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    bool retry = false,
  }) async {
    final uri = _buildUri(pathSegments);
    final encodedBody = body != null ? jsonEncode(body) : null;
    Future<Map<String, dynamic>> attempt() async {
      final response = await _http.post(
        uri,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          ...?headers,
        },
        body: encodedBody,
      );
      developer.log(
        '${response.statusCode} ${response.body.length}B',
        name: 'ApiClient',
      );
      return _handleJsonResponse(response);
    }
    final label = 'POST $uri';
    return retry
        ? _withRetry<Map<String, dynamic>>(attempt, label: label)
        : _withoutRetry<Map<String, dynamic>>(attempt, label: label);
  }

  /// Binary GET. Returns the raw response body as bytes.
  ///
  /// Defaults to retrying on transient failures and firing the offline hook
  /// on exhaustion. Cover-art tiles are high-volume (one fetch per album/
  /// artist tile) and a single failing thumbnail should not darken the
  /// whole app — those callers should pass `retry: false` and
  /// `triggerOfflineHook: false`.
  Future<Uint8List> getBytes(
    List<String> pathSegments, {
    Map<String, String>? query,
    Map<String, String>? headers,
    bool retry = true,
    bool triggerOfflineHook = true,
  }) async {
    final uri = _buildUri(pathSegments, query: query);
    Future<Uint8List> attempt() async {
      final response = await _http.get(uri, headers: headers);
      developer.log(
        '${response.statusCode} ${response.bodyBytes.length}B',
        name: 'ApiClient',
      );
      if (_isSuccess(response.statusCode)) {
        return response.bodyBytes;
      }
      throw _HttpFailureSignal(response.statusCode, response.body, response.headers);
    }
    final label = 'GET-bytes $uri';
    return retry
        ? _withRetry<Uint8List>(
            attempt,
            label: label,
            triggerOfflineHook: triggerOfflineHook,
          )
        : _withoutRetry<Uint8List>(
            attempt,
            label: label,
            triggerOfflineHook: triggerOfflineHook,
          );
  }

  /// Streaming send for callers that need a chunked response stream
  /// (download progress, prefetch). Retries apply ONLY to the initial
  /// handshake; once the StreamedResponse is returned, mid-stream failures
  /// belong to the caller. The [requestFactory] is invoked per attempt
  /// because `http.BaseRequest` is one-shot.
  Future<http.StreamedResponse> send(
    http.BaseRequest Function() requestFactory,
  ) async {
    return _withRetry<http.StreamedResponse>(
      () async {
        final request = requestFactory();
        final response = await _http.send(request);
        developer.log(
          '${response.statusCode} (streamed) ${request.url}',
          name: 'ApiClient',
        );
        if (_isSuccess(response.statusCode)) {
          return response;
        }
        // Drain so we don't leak the connection across the retry boundary.
        await response.stream.drain<void>();
        // Headers on StreamedResponse are case-insensitive map already.
        throw _HttpFailureSignal(response.statusCode, '', response.headers);
      },
      label: 'SEND',
    );
  }

  Map<String, dynamic> _handleJsonResponse(http.Response response) {
    if (_isSuccess(response.statusCode)) {
      if (response.body.isEmpty) return {};
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } on FormatException catch (e) {
        // Server returned 2xx but the body wasn't valid JSON. Retrying won't
        // help, so surface as an ApiException — caller decides what to do.
        throw ApiException(
          response.statusCode,
          'Malformed JSON response: ${e.message}',
        );
      } on TypeError catch (e) {
        // jsonDecode produced something other than Map<String, dynamic>
        // (e.g. a top-level array or string). Same logic: not retryable.
        throw ApiException(
          response.statusCode,
          'Unexpected JSON shape: $e',
        );
      }
    }
    throw _HttpFailureSignal(response.statusCode, response.body, response.headers);
  }

  bool _isSuccess(int code) => code >= 200 && code < 300;

  /// Pings `/`. Distinguishes "server unreachable" (eligible for offline
  /// mode) from "server replied with an error" (not offline — surface as an
  /// inline error). Pass `retry: false` when polling, so each poll is a
  /// single fast attempt rather than the 3-attempt request loop.
  Future<HealthResult> healthCheck({bool retry = true}) async {
    try {
      // A health check is a probe: its result is the HealthStatus returned
      // below, which every caller handles explicitly. It must NOT also flip
      // global offline mode via the transport-failure hook — that would let a
      // failed manual connection attempt strand the app in offline mode.
      final data = await getJson([], retry: retry, triggerOfflineHook: false);
      if (data['message'] == 'Healthy') return const HealthResult(HealthStatus.ok);
      return const HealthResult(HealthStatus.serverError, 'Unexpected response from server');
    } on ApiException catch (e) {
      return HealthResult(HealthStatus.serverError, 'Server error: ${e.statusCode}');
    } on NetworkException catch (e) {
      return HealthResult(HealthStatus.unreachable, 'Could not reach server: ${e.message}');
    } catch (e) {
      return HealthResult(HealthStatus.unreachable, 'Could not reach server: $e');
    }
  }

  String coverArtUrl(int coverArtId) => '$baseUrl/cover_art/$coverArtId';

  void close() {
    _http.close();
  }

  /// Runs [attempt] exactly once, wrapped in the per-attempt timeout. Logs
  /// the attempt and rethrows the raw classification signals
  /// ([_HttpFailureSignal], [SocketException], [TimeoutException],
  /// [http.ClientException], [ArgumentError]) for the layered helpers
  /// ([_withRetry], [_withoutRetry]) to decide what to do with.
  ///
  /// `Future.timeout` abandons the wait but does NOT cancel the underlying
  /// HTTP request — `package:http` has no public abort API, and even with
  /// one most servers don't honor a mid-handler client disconnect. So when
  /// a request times out locally the server may still finish the original.
  /// That's why `postJson`/`putJson` default to `retry: false`: a retried
  /// non-idempotent mutation could be processed twice. Opt in only when the
  /// endpoint is idempotent (same call repeated → same state) or advisory
  /// (failure is acceptable; duplicate execution does no harm).
  Future<T> _runAttempt<T>(
    Future<T> Function() attempt, {
    required String label,
    required int attemptNumber,
    required int totalAttempts,
  }) async {
    developer.log(
      '$label (attempt $attemptNumber/$totalAttempts)',
      name: 'ApiClient',
    );
    return await attempt().timeout(_perAttemptTimeout);
  }

  /// Runs [attempt] with retry on transient failures.
  ///
  /// Retries on:
  ///   - HTTP 408, 429, 502, 503, 504 (via [_HttpFailureSignal])
  ///   - SocketException, TimeoutException, http.ClientException
  ///   - ArgumentError (treated as a transport failure — typically a
  ///     malformed URL caused by an empty/invalid baseUrl)
  ///
  /// Honors `Retry-After` (seconds or HTTP-date) on any retryable status
  /// response that carries the header, clamped to [_maxRetryAfter]. The
  /// RFC defines Retry-After primarily for 429/503/3xx, but in practice
  /// proxies emit it on other 5xx codes; honoring it broadly is safe.
  /// Otherwise uses exponential backoff with full jitter:
  /// `delay = random(0, _baseDelay * 2^(n-1))` where n is the
  /// 1-indexed attempt number. Windows: 250ms, 500ms, 1000ms.
  ///
  /// On exhaustion throws [ApiException] (HTTP) or [NetworkException]
  /// (transport). No raw SocketException/TimeoutException/ClientException/
  /// ArgumentError escapes ApiClient via the request methods.
  Future<T> _withRetry<T>(
    Future<T> Function() attempt, {
    required String label,
    bool triggerOfflineHook = true,
  }) async {
    Object? lastNetworkCause;
    for (var attemptNumber = 1; attemptNumber <= _maxAttempts; attemptNumber++) {
      try {
        return await _runAttempt(
          attempt,
          label: label,
          attemptNumber: attemptNumber,
          totalAttempts: _maxAttempts,
        );
      } on _HttpFailureSignal catch (status) {
        if (!_retryableStatusCodes.contains(status.statusCode)) {
          throw ApiException(status.statusCode, status.body);
        }
        if (attemptNumber >= _maxAttempts) {
          throw ApiException(status.statusCode, status.body);
        }
        final delay = _delayForRetry(attemptNumber, status.headers);
        developer.log(
          '$label HTTP ${status.statusCode} — retrying in ${delay.inMilliseconds}ms',
          name: 'ApiClient',
        );
        await _delay(delay);
        continue;
      } on SocketException catch (e) {
        lastNetworkCause = e;
        if (attemptNumber >= _maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {});
        developer.log('$label socket error — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      } on TimeoutException catch (e) {
        lastNetworkCause = e;
        if (attemptNumber >= _maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {});
        developer.log('$label timeout — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      } on http.ClientException catch (e) {
        lastNetworkCause = e;
        if (attemptNumber >= _maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {});
        developer.log('$label client error — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      } on ArgumentError catch (e) {
        // Typically thrown by http when baseUrl is empty/malformed and the
        // resulting Uri has no scheme/host. Treat as a transport-level error
        // so callers see a typed NetworkException rather than a raw throw.
        lastNetworkCause = e;
        if (attemptNumber >= _maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {});
        developer.log('$label argument error — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      }
    }
    // All attempts exhausted on transport-level failures — signal offline.
    if (triggerOfflineHook) _fireNetworkFailure();
    throw NetworkException(
      lastNetworkCause?.toString() ?? 'unknown network error',
      cause: lastNetworkCause,
      attemptsMade: _maxAttempts,
    );
  }

  /// Runs [attempt] exactly once and converts failures to the same typed
  /// exceptions [_withRetry] produces — [ApiException] for HTTP failures
  /// (retryable or not, since there's no second chance to take), and
  /// [NetworkException]`(attemptsMade: 1)` for transport-layer errors.
  /// Used by `postJson`/`putJson` when `retry: false` so callers handle a
  /// uniform exception shape regardless of whether retries are enabled.
  Future<T> _withoutRetry<T>(
    Future<T> Function() attempt, {
    required String label,
    bool triggerOfflineHook = true,
  }) async {
    try {
      return await _runAttempt(
        attempt,
        label: label,
        attemptNumber: 1,
        totalAttempts: 1,
      );
    } on _HttpFailureSignal catch (status) {
      throw ApiException(status.statusCode, status.body);
    } on SocketException catch (e) {
      if (triggerOfflineHook) _fireNetworkFailure();
      throw NetworkException(e.toString(), cause: e, attemptsMade: 1);
    } on TimeoutException catch (e) {
      if (triggerOfflineHook) _fireNetworkFailure();
      throw NetworkException(e.toString(), cause: e, attemptsMade: 1);
    } on http.ClientException catch (e) {
      if (triggerOfflineHook) _fireNetworkFailure();
      throw NetworkException(e.toString(), cause: e, attemptsMade: 1);
    } on ArgumentError catch (e) {
      if (triggerOfflineHook) _fireNetworkFailure();
      throw NetworkException(e.toString(), cause: e, attemptsMade: 1);
    }
  }

  /// Returns the wait time before the next attempt. If the response carried
  /// a parseable Retry-After header, that wins (clamped to _maxRetryAfter).
  /// Otherwise: full-jitter exponential backoff.
  Duration _delayForRetry(int attemptNumber, Map<String, String> headers) {
    final retryAfter = _parseRetryAfter(_headerIgnoreCase(headers, 'retry-after'));
    if (retryAfter != null) {
      return retryAfter > _maxRetryAfter ? _maxRetryAfter : retryAfter;
    }
    // attemptNumber is 1-based; for n=1, window is _baseDelay = 250ms.
    // Using 2^(n-1) gives 250/500/1000 windows starting at n=1.
    final windowMs = _baseDelay.inMilliseconds * (1 << (attemptNumber - 1));
    final jittered = _random.nextInt(windowMs + 1);
    return Duration(milliseconds: jittered);
  }

  /// Case-insensitive header lookup. `http.Response` preserves whatever
  /// case the constructor was given (real IOClient lowercases, but tests
  /// and some intermediaries don't), so we look up tolerantly.
  String? _headerIgnoreCase(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// Parses a `Retry-After` header value, which can be either a non-negative
  /// integer (seconds) or an HTTP-date. Returns null on parse failure.
  Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      if (seconds < 0) return null;
      return Duration(seconds: seconds);
    }
    try {
      final date = HttpDate.parse(trimmed);
      final delta = date.difference(DateTime.now());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      return null;
    }
  }
}

/// Internal sentinel: an HTTP response that may or may not be retryable. The
/// retry helper inspects [statusCode] and either retries (transient codes),
/// converts to [ApiException] (non-retryable), or exhausts and converts to
/// [ApiException] (retryable but out of attempts).
class _HttpFailureSignal implements Exception {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  _HttpFailureSignal(this.statusCode, this.body, this.headers);
}
