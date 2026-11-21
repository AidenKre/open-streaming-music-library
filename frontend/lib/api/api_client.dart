import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:frontend/models/instance_stamp.dart';

import 'authenticated_client.dart';
import 'retry_policy.dart';

export 'retry_policy.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  late final Object? _detail = _parseDetail();

  Object? _parseDetail() {
    try {
      final body = jsonDecode(message);
      return body is Map ? body['detail'] : null;
    } catch (_) {
      return null;
    }
  }

  String? get errorCode {
    final value = details?['error'];
    return value is String ? value : null;
  }

  bool? get retryable {
    final value = details?['retryable'];
    return value is bool ? value : null;
  }

  /// A 4xx the server will answer the same way again (not auth, timeout,
  /// rate limit, or an explicitly retryable answer).
  bool get isDefinitiveRefusal =>
      statusCode >= 400 &&
      statusCode < 500 &&
      statusCode != 401 &&
      statusCode != 408 &&
      statusCode != 429 &&
      retryable != true;

  /// How long the server asked to wait (`retry_after_s`, a positive whole
  /// number of seconds); null when absent or malformed (unknown).
  Duration? get retryAfter {
    final seconds = details?['retry_after_s'];
    return seconds is int && seconds > 0 ? Duration(seconds: seconds) : null;
  }

  Map<String, dynamic>? get details {
    final detail = _detail;
    return detail is Map<String, dynamic> ? detail : null;
  }

  /// FastAPI field-validation errors, parsed through the shared envelope.
  List<dynamic>? get validationErrors => _detail is List ? _detail : null;

  /// Lets legacy callers keep showing only string-detail rejections.
  bool get hasStringDetail => _detail is String;

  String? get detailMessage {
    final detail = _detail;
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is List) {
      final messages = [
        for (final item in detail)
          if (item is Map && item['msg'] is String) item['msg'] as String,
      ];
      if (messages.isNotEmpty) return messages.join('; ');
    }
    if (detail is Map) {
      for (final key in const ['message', 'msg', 'error']) {
        final value = detail[key];
        if (value is String && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// How [ApiException.message] starts for a 2xx answer whose body is not
/// JSON at all; [ApiClient.healthCheck] reports it as
/// [HealthResult.bodyNotJson].
const _malformedJson = 'Malformed JSON response: ';

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

/// Thrown by [ApiClient.putStream] when its abort trigger completed: the
/// caller stopped the transfer. Not a network failure (no offline signal);
/// whether the server kept anything is for the caller to ask.
class UploadTransferAborted implements Exception {
  const UploadTransferAborted();

  @override
  String toString() => 'UploadTransferAborted';
}

typedef DelayFn = Future<void> Function(Duration);

/// Result of a health check. `unreachable` means the network call itself
/// failed (transport-level) — eligible for offline mode. `serverError` means
/// the server answered with a non-2xx (e.g. 500) or an unexpected body — the
/// server is up but misbehaving, so the user should see an inline error
/// rather than enter offline mode. At app launch only, an HTTP 5xx or 429
/// answer, or a 2xx answer that is not JSON (a web page in front of the
/// server) or is empty, is treated like `unreachable` (sign-off OPEN-A-04,
/// 2026-11-17; pre-merge review A5-02); see
/// [HealthResult.statusCode], [HealthResult.bodyNotJson] and
/// `SessionService.resumeSavedSession`.
enum HealthStatus { ok, serverError, unreachable }

class HealthResult {
  final HealthStatus status;
  final String? message;

  /// The status of an `ApiException` answer: the HTTP status of a non-2xx
  /// answer, and the 2xx status of a body that is not valid JSON or not a
  /// JSON object. Null for a well-formed JSON object that is not OSML's, for
  /// an empty body, and for transport failures.
  final int? statusCode;

  /// The answer was 2xx and its body is not JSON at all (a web page), or is
  /// empty (a bare `{}` counts as empty: the client cannot tell the two
  /// apart).
  final bool bodyNotJson;
  const HealthResult(
    this.status, [
    this.message,
    this.statusCode,
    this.bodyNotJson = false,
  ]);
  bool get isOk => status == HealthStatus.ok;
}

/// A fresh [ApiClient] with the usual test seams
/// applied (no-op delay, seeded jitter, no per-attempt timeout override).
@visibleForTesting
ApiClient testApiClient(String url, http.Client client) =>
    ApiClient(url, client).._applyTestSeams();

enum _HttpVerb { get, put, post, patch, delete }

/// Checks a response's server instance stamp (SC-01 rule 6); throws to
/// reject the response.
typedef InstanceStampCheck = Future<void> Function(String servedBy);

class ApiClient {
  ApiClient(this.baseUrl, http.Client inner) : _http = inner;

  bool _disposed = false;

  /// Ends this client's scope: clears its network-failure listeners and
  /// ignores any added afterwards, so a request that outlives its scope
  /// cannot flip the new scope offline (spec 7.2: "Network-failure listeners
  /// become per instance, so a request that outlives its scope can't flip
  /// the new scope offline").
  ///
  /// Deliberately never closes the inner [http.Client]: it is shared, and
  /// old-scope requests must be allowed to finish.
  void dispose() {
    _disposed = true;
    _networkFailureListeners.clear();
  }

  /// Listeners invoked when a normal request exhausts retries on a
  /// transport-level failure. Per instance, so each provider scope's client
  /// notifies only its own observers. Probe
  /// calls opt out via `triggerOfflineHook: false` (see [healthCheck]).
  ///
  /// Multiple observers can register independently (e.g. offline-mode
  /// notifier + telemetry breadcrumbs) without clobbering each other. Using
  /// a Set means re-registering the same listener is a no-op.
  ///
  /// There is deliberately no success counterpart: a received HTTP response
  /// (even a 2xx) does not prove the backend is healthy enough to resume
  /// normal work. Offline mode is exited only by a passing health check.
  final Set<void Function()> _networkFailureListeners = {};

  void addNetworkFailureListener(void Function() listener) {
    if (_disposed) return;
    _networkFailureListeners.add(listener);
  }

  void removeNetworkFailureListener(void Function() listener) {
    _networkFailureListeners.remove(listener);
  }

  @visibleForTesting
  void clearNetworkFailureListenersForTest() {
    _networkFailureListeners.clear();
  }

  void _fireNetworkFailure() {
    // Snapshot to tolerate listeners that remove themselves during dispatch.
    for (final listener in _networkFailureListeners.toList()) {
      listener();
    }
  }

  final String baseUrl;
  final http.Client _http;

  /// A client on the same URL over [transport], with this client's test
  /// seams; its network failures reach THIS client's listeners, so there is
  /// one offline path. The one place a derived client is built.
  ApiClient _sibling(http.Client transport) {
    final sibling = ApiClient(baseUrl, transport);
    sibling._delay = _delay;
    sibling._random = _random;
    sibling._perAttemptTimeoutOverride = _perAttemptTimeoutOverride;
    sibling._logSink = _logSink;
    sibling.addNetworkFailureListener(_fireNetworkFailure);
    return sibling;
  }

  /// A client on the same URL and transport that never carries the token (an
  /// [AuthenticatedClient]'s shared inner client is used bare) and has no 401
  /// hook, for public paths. Its network failures reach THIS client's
  /// listeners, so there is one offline path. Holds nothing to dispose. Any
  /// other transport is used as it is: only [AuthenticatedClient] adds a
  /// token.
  ApiClient withoutToken() {
    final transport = _http;
    return _sibling(
      transport is AuthenticatedClient ? transport.withoutToken() : transport,
    );
  }

  /// A sibling client (same URL, same transport, token kept) that runs
  /// [check] on the `X-Server-Instance-Id` stamp of every response before the
  /// caller sees it (SC-01 rule 6, extended from pages to writes). Its network
  /// failures reach THIS client's listeners.
  ///
  /// Pass the binding repository's `checkServedBy` (in practice: use
  /// `boundApiClientProvider`).
  ///
  /// On a mismatch the call throws `ServerInstanceChangedException` (from the
  /// check) instead of returning the body or throwing [ApiException]. It is
  /// not retried, so this client sends nothing further for that call.
  ///
  /// The caller must then leave its local row (pending edit, listen batch,
  /// upload operation) exactly as it was before the send, treating the request
  /// as not delivered; send nothing further in that pass; and report through
  /// `ServerBindingGate.reportDifferentInstance(connection, e)` with the
  /// connection captured together with its token (`awaitVerified()` then
  /// `verifiedConnection` in the same synchronous segment).
  ///
  /// No stamp (a pre-Phase-7 server) means no check; an unbound row or no row
  /// means no check either.
  ///
  /// Residual: the check runs on the RESPONSE, so a server that replaced the
  /// bound one between the connection check and the pass still receives the
  /// first state-changing request of that pass; the check limits it to one
  /// request per pass. Preventing that would need a stamped pre-flight request
  /// before every write, which was decided against (an extra round trip on
  /// every pass for a case that needs the server replaced in the seconds
  /// between the connection check and the pass).
  ///
  /// Any new transport method added to [ApiClient] (e.g. a streamed PUT) must
  /// run [_checkStamp] too.
  ApiClient withInstanceCheck(InstanceStampCheck check) =>
      _sibling(_http).._instanceCheck = check;

  InstanceStampCheck? _instanceCheck;

  /// The log-out/Disconnect revoke exemption (sign-off OPEN-M-11): a client
  /// whose transport sends exactly one request, the `POST auth/logout`, with
  /// the scope's token regardless of the binding gate. Null when this client
  /// carries no token. Take it while the revoke rule holds, use it once.
  ApiClient? revokeOnceClient() {
    final transport = _http;
    if (transport is! AuthenticatedClient) return null;
    return _sibling(transport.revokeExemption(_buildUri(['auth', 'logout'])));
  }

  /// The one place the stamp rule runs: no check or no stamp, nothing happens;
  /// otherwise the check's exception propagates unchanged.
  Future<void> _checkStamp(Map<String, String> responseHeaders) async {
    final check = _instanceCheck;
    if (check == null) return;
    final stamp = instanceStampFrom(responseHeaders);
    if (stamp != null) await check(stamp);
  }

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

  void _applyTestSeams() {
    _delay = (_) async {};
    _random = math.Random(0);
    _perAttemptTimeoutOverride = null;
  }

  void Function(String message) _logSink = (m) =>
      developer.log(m, name: 'ApiClient');

  void _log(String message) => _logSink(message);

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void setLogSinkForTest(void Function(String message) sink) {
    _logSink = sink;
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
      ),
    );
  }

  /// Like [getJson], but also returns the response headers (SC-01 rule 6:
  /// the page fetchers read the server's instance stamp).
  Future<({Map<String, dynamic> body, Map<String, String> headers})>
  getJsonResponse(
    List<String> pathSegments, {
    Map<String, String>? query,
    Map<String, String>? headers,
    RetryPolicy? policy,
  }) {
    return _request<({Map<String, dynamic> body, Map<String, String> headers})>(
      verb: _HttpVerb.get,
      pathSegments: pathSegments,
      query: query,
      headers: headers,
      decode: (response) =>
          (body: _handleJsonResponse(response), headers: response.headers),
      acceptJson: true,
      policy: _resolvePolicy(
        explicit: policy,
        retry: true,
        triggerOfflineHook: true,
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
      ),
    );
  }

  /// DELETE with no body. Defaults to **retrying** transient failures (unlike
  /// PUT/POST/PATCH) because a DELETE is remove-pending-work, not mint-new-work
  /// -- re-sending it after a dropped response is safe: the first attempt
  /// either hadn't taken effect yet (retry finishes the job) or had already
  /// taken effect (retry is a 200 no-op on an already-terminal/missing
  /// resource), never a duplicate side effect the way a retried POST would be.
  Future<Map<String, dynamic>> deleteJson(
    List<String> pathSegments, {
    Map<String, String>? headers,
    bool retry = true,
    RetryPolicy? policy,
  }) {
    return _request<Map<String, dynamic>>(
      verb: _HttpVerb.delete,
      pathSegments: pathSegments,
      headers: headers,
      decode: _handleJsonResponse,
      acceptJson: true,
      policy: _resolvePolicy(
        explicit: policy,
        retry: retry,
        triggerOfflineHook: true,
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
      ),
    );
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
      ),
    );
  }

  /// Resolves the effective policy from the legacy `retry` / `triggerOfflineHook`
  /// booleans and an optional explicit [explicit] override. When [explicit] is
  /// provided it wins outright; otherwise we pick `standard` vs `noRetry`
  /// from [retry] (each verb sets its own default for it) and apply the
  /// offline-hook opt-out via `copyWith` so callers keep getting the
  /// well-known constants without the boolean fork bleeding throughout the
  /// request methods.
  RetryPolicy _resolvePolicy({
    required RetryPolicy? explicit,
    required bool retry,
    required bool triggerOfflineHook,
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
        try {
          await _checkStamp(response.headers);
        } catch (_) {
          try {
            await response.stream.drain<void>();
          } catch (_) {}
          rethrow;
        }
        // Method and path only: query strings may carry a token (spec 7.2).
        _log('${response.statusCode} (streamed) ${request.method} ${request.url.path}');
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

  /// Streamed PUT of a request body that is never held in memory (Phase 7
  /// D25: the upload content PUT). [body] is read only as the transport
  /// sends it (its backpressure paces the reads); [length] is sent as
  /// Content-Length; [onProgress] gets the bytes handed to the transport so
  /// far (monotonic, ending at [length]).
  ///
  /// One attempt and no per-attempt timeout: a transfer retry restarts the
  /// file, which is the caller's decision (SC-14). A caller that wants a
  /// stall bound completes [abortTrigger]; the call then stops reading
  /// [body], cancels it, and throws [UploadTransferAborted].
  ///
  /// The answer goes through the instance-stamp check like every response;
  /// a 2xx JSON body is returned, a non-2xx is an [ApiException] (the SC-22
  /// envelope intact), a transport failure a [NetworkException]. An error
  /// from [body] itself is rethrown unchanged. The response is read up to a
  /// bounded size.
  Future<Map<String, dynamic>> putStream(
    List<String> pathSegments, {
    required Stream<List<int>> body,
    required int length,
    void Function(int sentBytes)? onProgress,
    Future<void>? abortTrigger,
    Map<String, String>? headers,
  }) {
    final uri = _buildUri(pathSegments);
    final aborted = Completer<void>();
    var wasAborted = false;
    Object? bodyError;
    StreamSubscription<List<int>>? inner;
    var sent = 0;

    // The transport pulls from this controller, so its backpressure paces
    // the reads of [body] (no sink.add, which has none).
    late final StreamController<List<int>> wrapper;
    wrapper = StreamController<List<int>>(
      onListen: () {
        if (wasAborted) return;
        inner = body.listen(
          (chunk) {
            sent += chunk.length;
            onProgress?.call(sent);
            wrapper.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            bodyError ??= error;
            inner?.cancel();
            wrapper.addError(error, stackTrace);
            wrapper.close();
          },
          onDone: wrapper.close,
          cancelOnError: true,
        );
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () => inner?.cancel(),
    );

    // The trigger completing, with a value or an error, is an abort.
    void abort() {
      if (wasAborted) return;
      wasAborted = true;
      inner?.cancel();
      if (!wrapper.isClosed) wrapper.close();
      aborted.complete();
    }

    abortTrigger?.then((_) => abort(), onError: (Object _) => abort());

    final request = _StreamedPut(
      uri,
      wrapper.stream,
      aborted.future,
      length,
    )..headers.addAll({
        'Content-Type': 'application/octet-stream',
        'Accept': 'application/json',
        ...?headers,
      });

    Future<Map<String, dynamic>> attempt() async {
      final http.StreamedResponse response;
      try {
        response = await Future.any<http.StreamedResponse>([
          _http.send(request),
          aborted.future.then<http.StreamedResponse>(
            (_) => throw const UploadTransferAborted(),
          ),
        ]);
      } on UploadTransferAborted {
        rethrow;
      } catch (_) {
        if (wasAborted) throw const UploadTransferAborted();
        final failure = bodyError;
        if (failure != null) throw failure;
        rethrow;
      }
      try {
        await _checkStamp(response.headers);
      } catch (_) {
        try {
          unawaited(response.stream.listen((_) {}).cancel());
        } catch (_) {}
        rethrow;
      }
      final bytes = await _readBounded(
        response.stream,
        1 << 20,
        abort: aborted.future,
      );
      _log('${response.statusCode} ${bytes.length}B');
      return _handleJsonResponse(
        http.Response.bytes(bytes, response.statusCode, headers: response.headers),
      );
    }

    return _runWithPolicy<Map<String, dynamic>>(
      attempt,
      label: 'PUT(stream) ${uri.path}',
      policy: RetryPolicy.noRetry,
      noTimeout: true,
    );
  }

  /// Reads [stream] up to [limit] bytes, then cancels it. When [abort]
  /// completes first the read is cancelled and [UploadTransferAborted] thrown.
  Future<Uint8List> _readBounded(
    Stream<List<int>> stream,
    int limit, {
    Future<void>? abort,
  }) {
    final done = Completer<Uint8List>();
    final out = BytesBuilder(copy: false);
    late StreamSubscription<List<int>> sub;
    sub = stream.listen(
      (chunk) {
        final room = limit - out.length;
        out.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
        if (out.length >= limit && !done.isCompleted) {
          sub.cancel();
          done.complete(out.takeBytes());
        }
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(out.takeBytes());
      },
      cancelOnError: true,
    );
    abort?.then((_) {
      if (done.isCompleted) return;
      sub.cancel();
      done.completeError(const UploadTransferAborted());
    });
    return done.future;
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
        case _HttpVerb.delete:
          response = await _http.delete(uri, headers: mergedHeaders);
      }
      // JSON-decoding callers see character-length; getBytes overrides the
      // log via its decode callback if it needs byte-length. Keeping
      // body.length here matches the pre-refactor log format exactly.
      _log('${response.statusCode} ${response.body.length}B');
      await _checkStamp(response.headers);
      return decode(response);
    }

    return _runWithPolicy<T>(
      attempt,
      label: '${_verbLabel(verb)} ${uri.path}',
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
      case _HttpVerb.delete:
        // DELETE has no body, so no Content-Type -- just Accept, same as GET.
        return {'Accept': 'application/json', ...?headers};
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
      case _HttpVerb.delete:
        return 'DELETE';
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
          '$_malformedJson${e.message}',
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
      // An empty 2xx body reads as `{}`, like a literal `{}`: either comes
      // from something in front of the server, not from OSML.
      if (data.isEmpty) {
        return const HealthResult(
            HealthStatus.serverError, 'Unexpected response from server', null, true);
      }
      return const HealthResult(HealthStatus.serverError, 'Unexpected response from server');
    } on ApiException catch (e) {
      return HealthResult(
        HealthStatus.serverError,
        'Server error: ${e.statusCode}',
        e.statusCode,
        _isSuccess(e.statusCode) && e.message.startsWith(_malformedJson),
      );
    } on NetworkException catch (e) {
      return HealthResult(HealthStatus.unreachable, 'Could not reach server: ${e.message}');
    } catch (e) {
      return HealthResult(HealthStatus.unreachable, 'Could not reach server: $e');
    }
  }

  String coverArtUrl(int coverArtId) => '$baseUrl/cover_art/$coverArtId';

  /// Runs [attempt] exactly once, wrapped in the per-attempt timeout. Logs
  /// the attempt and rethrows the raw classification signals
  /// ([_HttpFailureSignal], [SocketException], [OSError], [TimeoutException],
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
    bool noTimeout = false,
  }) async {
    _log('$label (attempt $attemptNumber/$totalAttempts)');
    if (noTimeout) return await attempt();
    return await attempt().timeout(perAttemptTimeout);
  }

  /// Runs [attempt] under [policy]. When `policy.maxAttempts == 1` this is
  /// effectively a single shot that converts failures to typed exceptions;
  /// otherwise it retries on transient signals with full-jitter exponential
  /// backoff (honoring `Retry-After` up to `policy.maxRetryAfter`).
  ///
  /// Retries on:
  ///   - HTTP codes in `policy.retryableStatusCodes` (via [_HttpFailureSignal])
  ///   - SocketException, OSError, TimeoutException, http.ClientException
  ///   - ArgumentError (treated as a transport failure — typically a
  ///     malformed URL caused by an empty/invalid baseUrl)
  ///
  /// On exhaustion throws [ApiException] (HTTP) or [NetworkException]
  /// (transport). No raw SocketException/OSError/TimeoutException/
  /// ClientException/ArgumentError escapes ApiClient via the request methods.
  Future<T> _runWithPolicy<T>(
    Future<T> Function() attempt, {
    required String label,
    required RetryPolicy policy,
    bool noTimeout = false,
  }) async {
    // Waits once, outside the per-attempt timeout, for a verdict that is
    // already pending; the token decision itself is made at send time.
    final transport = _http;
    if (transport is AuthenticatedClient) await transport.verdictSettled();
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
          noTimeout: noTimeout,
        );
      } on _HttpFailureSignal catch (status) {
        if (!policy.retryableStatusCodes.contains(status.statusCode)) {
          throw ApiException(status.statusCode, status.body);
        }
        if (attemptNumber >= maxAttempts) {
          throw ApiException(status.statusCode, status.body);
        }
        final delay = _delayForRetry(attemptNumber, status.headers, policy);
        _log('$label HTTP ${status.statusCode} — retrying in ${delay.inMilliseconds}ms');
        await _delay(delay);
        continue;
      } catch (e) {
        final kind = _transportFailureKind(e);
        if (kind == null) rethrow;
        lastNetworkCause = e;
        if (attemptNumber >= maxAttempts) break;
        final delay = _delayForRetry(attemptNumber, const {}, policy);
        _log('$label $kind — retrying in ${delay.inMilliseconds}ms');
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

  /// The log name of a transport-level failure the request loop retries, or
  /// null for anything else (which propagates unchanged):
  ///   - SocketException
  ///   - a bare OSError: dart:io can throw one (not wrapped in
  ///     SocketException) when a connection is reset during connect, e.g. a
  ///     proxy or restarting server accepting and immediately dropping it
  ///   - TimeoutException (the per-attempt timeout)
  ///   - http.ClientException
  ///   - ArgumentError: typically thrown by http when baseUrl is
  ///     empty/malformed and the resulting Uri has no scheme/host; treated as
  ///     a transport-level error so callers see a typed NetworkException
  ///     rather than a raw throw
  static String? _transportFailureKind(Object e) {
    if (e is SocketException) return 'socket error';
    if (e is OSError) return 'OS error';
    if (e is TimeoutException) return 'timeout';
    if (e is http.ClientException) return 'client error';
    if (e is ArgumentError) return 'argument error';
    return null;
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

/// The streamed content PUT: the transport pulls [finalize]'s stream itself.
class _StreamedPut extends http.BaseRequest implements http.Abortable {
  _StreamedPut(Uri url, this._body, this._abortTrigger, int length)
    : super('PUT', url) {
    contentLength = length;
  }

  final Stream<List<int>> _body;
  final Future<void> _abortTrigger;

  @override
  Future<void> get abortTrigger => _abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}
