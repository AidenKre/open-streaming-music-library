import 'package:flutter/foundation.dart';

/// Value object describing how a single [ApiClient] request should retry on
/// transient failures.
///
/// `maxAttempts == 1` means "no retry": the request runs once and any failure
/// converts directly to its typed exception ([ApiException] or
/// [NetworkException]`(attemptsMade: 1)`). For `maxAttempts > 1`, transient
/// HTTP statuses in [retryableStatusCodes] and transport-layer errors are
/// retried with full-jitter exponential backoff anchored on [baseDelay], and
/// a `Retry-After` header (seconds or HTTP-date) overrides the backoff up to
/// [maxRetryAfter].
///
/// [perAttemptTimeout] bounds how long any single attempt may wait for the
/// HTTP response (the underlying request is not actually cancelled — see the
/// note at `ApiClient._runAttempt`).
///
/// [triggerOfflineHook] is the policy-level opt-out for the global
/// network-failure listeners: probes (health check, cover art) want their
/// own failure to NOT flip the app into offline mode.
@immutable
class RetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxRetryAfter;
  final Duration perAttemptTimeout;
  final Set<int> retryableStatusCodes;
  final bool triggerOfflineHook;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxRetryAfter = const Duration(seconds: 10),
    this.perAttemptTimeout = const Duration(seconds: 10),
    this.retryableStatusCodes = const {408, 429, 502, 503, 504},
    this.triggerOfflineHook = true,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be >= 1');

  /// Default for idempotent GETs: 3 attempts, fires the offline hook on
  /// transport exhaustion.
  static const RetryPolicy standard = RetryPolicy();

  /// Single-attempt policy for non-idempotent mutations (PUT/POST default)
  /// and for health-probe one-shots. Still fires the offline hook unless
  /// explicitly opted out (see [coverArt] and `healthCheck`).
  static const RetryPolicy noRetry = RetryPolicy(maxAttempts: 1);

  /// Cover-art tiles: single attempt, and a failing thumbnail must NOT
  /// flip the whole app into offline mode.
  static const RetryPolicy coverArt = RetryPolicy(
    maxAttempts: 1,
    triggerOfflineHook: false,
  );

  RetryPolicy copyWith({
    int? maxAttempts,
    Duration? baseDelay,
    Duration? maxRetryAfter,
    Duration? perAttemptTimeout,
    Set<int>? retryableStatusCodes,
    bool? triggerOfflineHook,
  }) {
    return RetryPolicy(
      maxAttempts: maxAttempts ?? this.maxAttempts,
      baseDelay: baseDelay ?? this.baseDelay,
      maxRetryAfter: maxRetryAfter ?? this.maxRetryAfter,
      perAttemptTimeout: perAttemptTimeout ?? this.perAttemptTimeout,
      retryableStatusCodes: retryableStatusCodes ?? this.retryableStatusCodes,
      triggerOfflineHook: triggerOfflineHook ?? this.triggerOfflineHook,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RetryPolicy) return false;
    return maxAttempts == other.maxAttempts &&
        baseDelay == other.baseDelay &&
        maxRetryAfter == other.maxRetryAfter &&
        perAttemptTimeout == other.perAttemptTimeout &&
        triggerOfflineHook == other.triggerOfflineHook &&
        _setEquals(retryableStatusCodes, other.retryableStatusCodes);
  }

  @override
  int get hashCode => Object.hash(
        maxAttempts,
        baseDelay,
        maxRetryAfter,
        perAttemptTimeout,
        triggerOfflineHook,
        // Order-independent hash for the status-code set.
        Object.hashAllUnordered(retryableStatusCodes),
      );

  @override
  String toString() =>
      'RetryPolicy(maxAttempts: $maxAttempts, baseDelay: $baseDelay, '
      'maxRetryAfter: $maxRetryAfter, perAttemptTimeout: $perAttemptTimeout, '
      'retryableStatusCodes: $retryableStatusCodes, '
      'triggerOfflineHook: $triggerOfflineHook)';

  static bool _setEquals(Set<int> a, Set<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }
}
