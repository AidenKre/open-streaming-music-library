import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/retry_policy.dart';

void main() {
  group('RetryPolicy — defaults & presets', () {
    test('default constructor matches the documented standard policy', () {
      const p = RetryPolicy();
      expect(p.maxAttempts, 3);
      expect(p.baseDelay, const Duration(milliseconds: 250));
      expect(p.maxRetryAfter, const Duration(seconds: 10));
      expect(p.perAttemptTimeout, const Duration(seconds: 10));
      expect(p.retryableStatusCodes, {408, 429, 502, 503, 504});
      expect(p.triggerOfflineHook, isTrue);
    });

    test('RetryPolicy.standard equals the default constructor', () {
      expect(RetryPolicy.standard, const RetryPolicy());
    });

    test('RetryPolicy.noRetry sets maxAttempts=1 and keeps other defaults', () {
      const p = RetryPolicy.noRetry;
      expect(p.maxAttempts, 1);
      expect(p.triggerOfflineHook, isTrue);
      expect(p.perAttemptTimeout, const Duration(seconds: 10));
    });

    test('RetryPolicy.coverArt is single-attempt AND opts out of offline hook', () {
      const p = RetryPolicy.coverArt;
      expect(p.maxAttempts, 1);
      expect(p.triggerOfflineHook, isFalse);
    });

    test('assertion: maxAttempts must be >= 1', () {
      expect(() => RetryPolicy(maxAttempts: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('RetryPolicy — equality & hashCode', () {
    test('two default-constructed instances are equal', () {
      expect(const RetryPolicy() == const RetryPolicy(), isTrue);
      expect(const RetryPolicy().hashCode, const RetryPolicy().hashCode);
    });

    test('differs when maxAttempts differs', () {
      expect(
        const RetryPolicy() == const RetryPolicy(maxAttempts: 5),
        isFalse,
      );
    });

    test('differs when triggerOfflineHook differs', () {
      expect(
        const RetryPolicy() == const RetryPolicy(triggerOfflineHook: false),
        isFalse,
      );
    });

    test('differs when retryableStatusCodes differs', () {
      const a = RetryPolicy(retryableStatusCodes: {408, 503});
      const b = RetryPolicy(retryableStatusCodes: {408, 504});
      expect(a == b, isFalse);
    });

    test('equal when retryableStatusCodes contain the same codes (set semantics)', () {
      const a = RetryPolicy(retryableStatusCodes: {408, 503});
      const b = RetryPolicy(retryableStatusCodes: {503, 408});
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('identical instance comparison short-circuits to true', () {
      const p = RetryPolicy();
      expect(p == p, isTrue);
    });

    test('comparing with a non-RetryPolicy returns false', () {
      // Casting through Object avoids the static type-mismatch lint; we
      // genuinely want to assert the runtime guard inside operator==.
      final Object notAPolicy = 'not a policy';
      // ignore: unrelated_type_equality_checks
      expect(const RetryPolicy() == notAPolicy, isFalse);
    });
  });

  group('RetryPolicy — copyWith', () {
    test('copyWith with no args returns an equal instance', () {
      const original = RetryPolicy();
      expect(original.copyWith(), original);
    });

    test('copyWith overrides only the named fields', () {
      const original = RetryPolicy();
      final modified = original.copyWith(maxAttempts: 7);
      expect(modified.maxAttempts, 7);
      // Everything else unchanged.
      expect(modified.baseDelay, original.baseDelay);
      expect(modified.maxRetryAfter, original.maxRetryAfter);
      expect(modified.perAttemptTimeout, original.perAttemptTimeout);
      expect(modified.retryableStatusCodes, original.retryableStatusCodes);
      expect(modified.triggerOfflineHook, original.triggerOfflineHook);
    });

    test('copyWith can flip triggerOfflineHook independently', () {
      final flipped = RetryPolicy.standard.copyWith(triggerOfflineHook: false);
      expect(flipped.triggerOfflineHook, isFalse);
      expect(flipped.maxAttempts, RetryPolicy.standard.maxAttempts);
    });

    test('copyWith preserves a custom retryableStatusCodes set', () {
      const original = RetryPolicy(retryableStatusCodes: {503});
      final modified = original.copyWith(baseDelay: const Duration(seconds: 1));
      expect(modified.retryableStatusCodes, {503});
    });
  });

  group('RetryPolicy — toString', () {
    test('includes the key fields', () {
      final s = const RetryPolicy().toString();
      expect(s, contains('maxAttempts: 3'));
      expect(s, contains('triggerOfflineHook: true'));
    });
  });
}
