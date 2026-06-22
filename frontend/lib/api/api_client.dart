import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'retry_policy.dart';

export 'retry_policy.dart';

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

enum _HttpVerb { get, put, post, patch }

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

  // Test seams. Tests inject a no-op delay + short timeout to run in
  // milliseconds; production uses Future.delayed and the policy's own
  // per-attempt timeout (10s by default).
  DelayFn _delay = Future.delayed;
  math.Random _random = math.Random();

  // Optional instance-level override for the per-attempt timeout. When set,
  // it takes precedence over `policy.perAttemptTimeout` so tests can shrink
  // a long hang into a millisecond-scale assertion without rebuilding every
  // call site to pass a custom policy.
  Duration? _perAttemptTimeoutOverride;

  static void init(String url) {
    instance.baseUrl = url;
  }

  @visibleForTesting
  static void initForTest(String url, http.Client httpClient) {
    instance.baseUrl = url;
    instance._http = httpClient;
    instance._delay = (_) async {};
    instance._random = math.Random(0);
    instance._perAttemptTimeoutOverride = null;
  }

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void setDelayFnForTest(DelayFn fn) {
    _delay = fn;
  }

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void setPerAttemptTimeoutForTest(Duration timeout) {
    _perAttemptTimeoutOverride = timeout;
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
  /// is its own retry loop), or pass an explicit [policy] for full control.
  Future<Map<String, dynamic>> getJson(
    List<String> pathSegments, {
    Map<String, String>? query,
    Map<String, String>? headers,
    bool retry = true,
    bool triggerOfflineHook = true,
    RetryPolicy? policy,
  }) {
    return _request<Map<String, dynamic>>(
      verb: _HttpVerb.get,
      pathSegments: pathSegments,
      query: query,
      headers: headers,
      decode: _handleJsonResponse,
      acceptJson: true,
      policy: _resolvePolicy(
        explicit: policy,
        retry: retry,
        triggerOfflineHook: triggerOfflineHook,
        defaultRetry: true,
      ),
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
    RetryPolicy? policy,
  }) {
    return _request<Map<String, dynamic>>(
      verb: _HttpVerb.put,
      pathSegments: pathSegments,
      headers: headers,
      jsonBody: body,
      decode: _handleJsonResponse,
      acceptJson: true,
      policy: _resolvePolicy(
        explicit: policy,
        retry: retry,
        triggerOfflineHook: true,
        defaultRetry: false,
      ),
    );
  }

  /// PATCH with JSON body (partial update). Defaults to a **single attempt**;
  /// the outbox flush opts into `retry: true` because the payload carries the
  /// full desired state — but that only retries transport errors / 5xx in
  /// [RetryPolicy.retryableStatusCodes], so 409/404/410 still bubble as
  /// [ApiException] for the conflict / track-gone paths.
  Future<Map<String, dynamic>> patchJson(
    List<String> pathSegments, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    bool retry = false,
    RetryPolicy? policy,
  }) {
    return _request<Map<String, dynamic>>(
      verb: _HttpVerb.patch,
      pathSegments: pathSegments,
      headers: headers,
      jsonBody: body,
      decode: _handleJsonResponse,
      acceptJson: true,
      policy: _resolvePolicy(
        explicit: policy,
        retry: retry,
        triggerOfflineHook: true,
        defaultRetry: false,
      ),
    );
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
    RetryPolicy? policy,
  }) {
    return _request<Map<String, dynamic>>(
      verb: _HttpVerb.post,
      pathSegments: pathSegments,
      headers: headers,
      jsonBody: body,
      decode: _handleJsonResponse,
      acceptJson: true,
      policy: _resolvePolicy(
        explicit: policy,
        retry: retry,
        triggerOfflineHook: true,
        defaultRetry: false,
      ),
    );
  }

  /// Binary GET. Returns the raw response body as bytes.
  ///
  /// Defaults to retrying on transient failures and firing the offline hook
  /// on exhaustion. Cover-art tiles are high-volume (one fetch per album/
  /// artist tile) and a single failing thumbnail should not darken the
  /// whole app — those callers should pass `retry: false` and
  /// `triggerOfflineHook: false` (or `policy: RetryPolicy.coverArt`).
  Future<Uint8List> getBytes(
    List<String> pathSegments, {
    Map<String, String>? query,
    Map<String, String>? headers,
    bool retry = true,
    bool triggerOfflineHook = true,
    RetryPolicy? policy,
  }) {
    return _request<Uint8List>(
      verb: _HttpVerb.get,
      pathSegments: pathSegments,
      query: query,
      headers: headers,
      decode: (response) {
        if (_isSuccess(response.statusCode)) {
          return response.bodyBytes;
        }
        throw _HttpFailureSignal(
          response.statusCode,
          response.body,
          response.headers,
        );
      },
      acceptJson: false,
      policy: _resolvePolicy(
        explicit: policy,
        retry: retry,
        triggerOfflineHook: triggerOfflineHook,
        defaultRetry: true,
      ),
    );
  }

  /// Resolves the effective policy from the legacy `retry` / `triggerOfflineHook`
  /// booleans and an optional explicit [explicit] override. When [explicit] is
  /// provided it wins outright; otherwise we pick `standard` vs `noRetry`
  /// based on the verb's default and apply the offline-hook opt-out via
  /// `copyWith` so callers keep getting the well-known constants without
  /// the boolean fork bleeding throughout the request methods.
  RetryPolicy _resolvePolicy({
    required RetryPolicy? explicit,
    required bool retry,
    required bool triggerOfflineHook,
    required bool defaultRetry,
  }) {
    if (explicit != null) {
      return triggerOfflineHook
          ? explicit
          : explicit.copyWith(triggerOfflineHook: false);
    }
    final base = retry ? RetryPolicy.standard : RetryPolicy.noRetry;
    return triggerOfflineHook
        ? base
        : base.copyWith(triggerOfflineHook: false);
  }

  /// Streaming send for callers that need a chunked response stream
  /// (download progress, prefetch). Retries apply ONLY to the initial
  /// handshake; once the StreamedResponse is returned, mid-stream failures
  /// belong to the caller. The [requestFactory] is invoked per attempt
  /// because `http.BaseRequest` is one-shot.
  Future<http.StreamedResponse> send(
    http.BaseRequest Function() requestFactory,
  ) async {
    return _runWithPolicy<http.StreamedResponse>(
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
      policy: RetryPolicy.standard,
    );
  }

  /// Central request method. All four verb wrappers funnel through here so
  /// the retry loop, timeout, header handling, and offline-hook semantics
  /// live in exactly one place.
  ///
  /// [acceptJson] controls whether `Accept: application/json` is auto-injected:
  /// JSON wrappers want it (was the previous behaviour); `getBytes` does NOT
  /// (cover-art etc. set no defaults, and a null `headers` map must remain
  /// null to preserve the pre-refactor request shape exactly).
  Future<T> _request<T>({
    required _HttpVerb verb,
    required List<String> pathSegments,
    required T Function(http.Response) decode,
    required bool acceptJson,
    Map<String, String>? query,
    Map<String, String>? headers,
    Object? jsonBody,
    RetryPolicy policy = RetryPolicy.standard,
  }) {
    final uri = _buildUri(pathSegments, query: query);
    final encodedBody = jsonBody != null ? jsonEncode(jsonBody) : null;
    final mergedHeaders = _mergeHeaders(verb, headers, acceptJson: acceptJson);

    Future<T> attempt() async {
      final http.Response response;
      switch (verb) {
        case _HttpVerb.get:
          response = await _http.get(uri, headers: mergedHeaders);
        case _HttpVerb.put:
          response = await _http.put(
            uri,
            headers: mergedHeaders,
            body: encodedBody,
          );
        case _HttpVerb.post:
          response = await _http.post(
            uri,
            headers: mergedHeaders,
            body: encodedBody,
          );
        case _HttpVerb.patch:
          response = await _http.patch(
            uri,
            headers: mergedHeaders,
            body: encodedBody,
          );
      }
      // JSON-decoding callers see character-length; getBytes overrides the
      // log via its decode callback if it needs byte-length. Keeping
      // body.length here matches the pre-refactor log format exactly.
      developer.log(
        '${response.statusCode} ${response.body.length}B',
        name: 'ApiClient',
      );
      return decode(response);
    }

    return _runWithPolicy<T>(
      attempt,
      label: '${_verbLabel(verb)} $uri',
      policy: policy,
    );
  }

  /// GET requests omit `Content-Type`; bytes-GETs additionally omit `Accept`
  /// (callers pass their own when needed) and must preserve a null `headers`
  /// map verbatim, since `package:http` distinguishes that from an empty map
  /// in its outgoing request shape. Keeping the merge in one place means a
  /// future header tweak — auth, tracing — touches a single function.
  Map<String, String>? _mergeHeaders(
    _HttpVerb verb,
    Map<String, String>? headers, {
    required bool acceptJson,
  }) {
    switch (verb) {
      case _HttpVerb.get:
        if (!acceptJson) {
          // Bytes-GET path: leave the caller's headers (incl. null) untouched.
          return headers;
        }
        return {'Accept': 'application/json', ...?headers};
      case _HttpVerb.put:
      case _HttpVerb.post:
      case _HttpVerb.patch:
        return {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          ...?headers,
        };
    }
  }

  String _verbLabel(_HttpVerb verb) {
    switch (verb) {
      case _HttpVerb.get:
        return 'GET';
      case _HttpVerb.put:
        return 'PUT';
      case _HttpVerb.post:
        return 'POST';
      case _HttpVerb.patch:
        return 'PATCH';
    }
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
  /// [http.ClientException], [ArgumentError]) for [_runWithPolicy] to
  /// decide what to do with.
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
    required Duration perAttemptTimeout,
  }) async {
    developer.log(
      '$label (attempt $attemptNumber/$totalAttempts)',
      name: 'ApiClient',
    );
    return await attempt().timeout(perAttemptTimeout);
  }

  /// Runs [attempt] under [policy]. When `policy.maxAttempts == 1` this is
  /// effectively a single shot that converts failures to typed exceptions;
  /// otherwise it retries on transient signals with full-jitter exponential
  /// backoff (honoring `Retry-After` up to `policy.maxRetryAfter`).
  ///
  /// Retries on:
  ///   - HTTP codes in `policy.retryableStatusCodes` (via [_HttpFailureSignal])
  ///   - SocketException, TimeoutException, http.ClientException
  ///   - ArgumentError (treated as a transport failure — typically a
  ///     malformed URL caused by an empty/invalid baseUrl)
  ///
  /// On exhaustion throws [ApiException] (HTTP) or [NetworkException]
  /// (transport). No raw SocketException/TimeoutException/ClientException/
  /// ArgumentError escapes ApiClient via the request methods.
  Future<T> _runWithPolicy<T>(
    Future<T> Function() attempt, {
    required String label,
    required RetryPolicy policy,
  }) async {
    final maxAttempts = policy.maxAttempts;
    final perAttemptTimeout =
        _perAttemptTimeoutOverride ?? policy.perAttemptTimeout;
    Object? lastNetworkCause;
    for (var attemptNumber = 1; attemptNumber <= maxAttempts; attemptNumber++) {
      try {
        return await _runAttempt(
          attempt,
          label: label,
          attemptNumber: attemptNumber,
          totalAttempts: maxAttempts,
          perAttemptTimeout: perAttemptTimeout,
        );
      } on _HttpFailureSignal catch (status) {
        if (!policy.retryableStatusCodes.contains(status.statusCode)) {
          throw ApiException(status.statusCode, status.body);
        }
        if (attemptNumber >= maxAttempts) {
          throw ApiException(status.statusCode, status.body);
        }
        final delay = _delayForRetry(attemptNumber, status.headers, policy);
        developer.log(
          '$label HTTP ${status.statusCode} — retrying in ${delay.inMilliseconds}ms',
          name: 'ApiClient',
        );
        await _delay(delay);
        continue;
      } on SocketException catch (e) {
        lastNetworkCause = e;
        if (attemptNumber >= maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {}, policy);
        developer.log('$label socket error — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      } on TimeoutException catch (e) {
        lastNetworkCause = e;
        if (attemptNumber >= maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {}, policy);
        developer.log('$label timeout — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      } on http.ClientException catch (e) {
        lastNetworkCause = e;
        if (attemptNumber >= maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {}, policy);
        developer.log('$label client error — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      } on ArgumentError catch (e) {
        // Typically thrown by http when baseUrl is empty/malformed and the
        // resulting Uri has no scheme/host. Treat as a transport-level error
        // so callers see a typed NetworkException rather than a raw throw.
        lastNetworkCause = e;
        if (attemptNumber >= maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {}, policy);
        developer.log('$label argument error — retrying in ${delay.inMilliseconds}ms', name: 'ApiClient');
        await _delay(delay);
        continue;
      }
    }
    // All attempts exhausted on transport-level failures — signal offline.
    if (policy.triggerOfflineHook) _fireNetworkFailure();
    throw NetworkException(
      lastNetworkCause?.toString() ?? 'unknown network error',
      cause: lastNetworkCause,
      attemptsMade: maxAttempts,
    );
  }

  /// Returns the wait time before the next attempt. If the response carried
  /// a parseable Retry-After header, that wins (clamped to policy.maxRetryAfter).
  /// Otherwise: full-jitter exponential backoff anchored on policy.baseDelay.
  Duration _delayForRetry(
    int attemptNumber,
    Map<String, String> headers,
    RetryPolicy policy,
  ) {
    final retryAfter = _parseRetryAfter(_headerIgnoreCase(headers, 'retry-after'));
    if (retryAfter != null) {
      return retryAfter > policy.maxRetryAfter ? policy.maxRetryAfter : retryAfter;
    }
    // attemptNumber is 1-based; for n=1, window is baseDelay = 250ms.
    // Using 2^(n-1) gives 250/500/1000 windows starting at n=1.
    final windowMs = policy.baseDelay.inMilliseconds * (1 << (attemptNumber - 1));
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
