// SC-22 envelope: a retryable answer may name how long to wait
// (`retry_after_s`, e.g. 503 `upload_slots_busy`). Unknown stays null.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';

ApiException _with(Object? detail) =>
    ApiException(503, jsonEncode({'detail': detail}));

void main() {
  test('retry_after_s seconds become retryAfter', () {
    final e = _with({
      'error': 'upload_slots_busy',
      'message': 'busy',
      'retryable': true,
      'retry_after_s': 5,
    });

    expect(e.retryAfter, const Duration(seconds: 5));
    expect(e.retryable, isTrue);
    expect(e.errorCode, 'upload_slots_busy');
  });

  test('absent, null, wrong-typed or non-positive values are unknown', () {
    for (final value in [null, '5', 2.5, 0, -3, true]) {
      expect(
        _with({'error': 'x', 'retryable': true, 'retry_after_s': value})
            .retryAfter,
        isNull,
        reason: '$value',
      );
    }
    expect(_with({'error': 'x', 'retryable': true}).retryAfter, isNull);
    expect(_with('plain string').retryAfter, isNull);
    expect(ApiException(503, 'not json').retryAfter, isNull);
  });
}
