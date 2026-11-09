// SC-22 client side: ApiException exposes the typed error envelope
// ({"detail": {"error", "message", "retryable", ...extra}}) through lazily
// parsed, tolerant getters, replacing the per-feature ad-hoc parsers.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';

ApiException _ex(int status, Object? body) =>
    ApiException(status, body is String ? body : jsonEncode(body));

void main() {
  group('typed envelope', () {
    final e = _ex(409, {
      'detail': {
        'error': 'history_event_conflict',
        'message': 'Different values.',
        'retryable': false,
        'conflicting_event_uuids': ['a', 'b'],
      },
    });

    test('errorCode', () => expect(e.errorCode, 'history_event_conflict'));
    test('retryable', () => expect(e.retryable, isFalse));
    test('details carries code-specific fields', () {
      expect(e.details?['conflicting_event_uuids'], ['a', 'b']);
    });
    test('detailMessage prefers the human message', () {
      expect(e.detailMessage, 'Different values.');
    });
  });

  test('legacy detail.error without message/retryable', () {
    final e = _ex(409, {
      'detail': {'error': 'revision_conflict', 'current_revision': 7},
    });
    expect(e.errorCode, 'revision_conflict');
    // Unknown is not false: an absent flag stays null.
    expect(e.retryable, isNull);
    expect(e.details?['current_revision'], 7);
    expect(e.detailMessage, 'revision_conflict');
  });

  test('retryable true', () {
    expect(_ex(503, {
      'detail': {'error': 'busy', 'message': 'm', 'retryable': true},
    }).retryable, isTrue);
  });

  test('string detail: no code, message is the string', () {
    final e = _ex(404, {'detail': 'Track not found'});
    expect(e.errorCode, isNull);
    expect(e.details, isNull);
    expect(e.retryable, isNull);
    expect(e.detailMessage, 'Track not found');
  });

  test('FastAPI validation list detail joins the msgs', () {
    final e = _ex(422, {
      'detail': [
        {'loc': ['body', 'x'], 'msg': 'field required', 'type': 'missing'},
        {'loc': ['body', 'y'], 'msg': 'too long', 'type': 'string_too_long'},
      ],
    });
    expect(e.errorCode, isNull);
    expect(e.detailMessage, 'field required; too long');
  });

  test('non-JSON, non-object and malformed bodies are tolerated', () {
    for (final body in [
      'Internal Server Error',
      '',
      '[1,2]',
      '{"detail": 5}',
      '{"detail": {"error": 3, "retryable": "yes"}}',
      '{"nodetail": true}',
    ]) {
      final e = ApiException(500, body);
      expect(e.errorCode, isNull, reason: body);
      expect(e.retryable, isNull, reason: body);
      expect(e.detailMessage, isNull, reason: body);
    }
  });

  test('statusCode and raw message are unchanged', () {
    final e = ApiException(500, 'raw body');
    expect(e.statusCode, 500);
    expect(e.message, 'raw body');
    expect(e.toString(), 'ApiException(500): raw body');
  });
}
