// Refactor A.3 slice 2: the failure rules the upload and deletion managers
// share. `refusalIsFinal` is NOT `ApiException.isDefinitiveRefusal`: it
// ignores the server's `retryable` flag (a refused review answer or deletion
// is a frozen body that would be refused again).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/operations/submission_failure_rules.dart';

import '../../helpers/fake_uploads_api.dart' show apiError;

void main() {
  group('refusalIsFinal', () {
    for (final status in [400, 403, 404, 409, 413, 422, 499]) {
      for (final retryable in [true, false, null]) {
        test('$status (retryable: $retryable) is final, with its code', () {
          final e = apiError(status, 'some_code', retryable: retryable);
          expect(
            refusalIsFinal(e),
            isA<SubmissionTerminal>().having((t) => t.code, 'code', 'some_code'),
          );
        });
      }
    }

    test('where it differs from isDefinitiveRefusal: a 4xx the server calls '
        'retryable', () {
      final e = apiError(422, 'tag_write_unsupported', retryable: true);
      expect(e.isDefinitiveRefusal, isFalse);
      expect(refusalIsFinal(e), isA<SubmissionTerminal>());
    });

    test('an answer without an error code is final as http_<status>', () {
      expect(
        refusalIsFinal(ApiException(404, 'not json')),
        isA<SubmissionTerminal>().having((t) => t.code, 'code', 'http_404'),
      );
    });

    for (final status in [401, 408, 429, 500, 503, 507, 399, 302, 200]) {
      for (final retryable in [true, false]) {
        test('$status (retryable: $retryable) is not a refusal', () {
          expect(
            refusalIsFinal(apiError(status, 'some_code', retryable: retryable)),
            isNull,
          );
        });
      }
    }

    test('anything that is not an HTTP answer is not a refusal', () {
      expect(refusalIsFinal(NetworkException('lost', attemptsMade: 1)), isNull);
      expect(refusalIsFinal(TimeoutException('slow')), isNull);
      expect(refusalIsFinal(StateError('x')), isNull);
      expect(
        refusalIsFinal(StatusQueryFailed(apiError(403, 'forbidden'))),
        isNull,
        reason: 'a failed status query never settles an operation as refused',
      );
    });
  });

  group('isUnauthorized', () {
    test('only a 401 answer', () {
      expect(isUnauthorized(apiError(401, 'auth_required')), isTrue);
      expect(isUnauthorized(apiError(403, 'forbidden')), isFalse);
      expect(isUnauthorized(NetworkException('lost', attemptsMade: 1)), isFalse);
      expect(
        isUnauthorized(StatusQueryFailed(apiError(401, 'auth_required'))),
        isFalse,
        reason: 'the caller unwraps a failed status query first',
      );
    });
  });
}
