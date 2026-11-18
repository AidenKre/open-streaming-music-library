// The failure rules the upload manager and the deletion manager share for
// what they send through [DurableSubmission]. Model code: nothing from ui/.
import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/operations/durable_submission.dart';

/// The managers' rule for a refused review answer (upload commit, resolve
/// duplicate) and a refused deletion submission: every 4xx except 401, 408
/// and 429 is final, WHATEVER the server's `retryable` flag says. Null for
/// anything else (the caller's next rule, or the built-in classification,
/// decides).
///
/// It differs from [ApiException.isDefinitiveRefusal] on purpose. That rule
/// honours `retryable`, and it is the one [DurableSubmission] applies by
/// itself, so the upload allocation and the content transfer follow it (a
/// busy slot or a full disk may pass later). A review answer or a deletion
/// is a frozen body the person confirmed: the same body would be refused
/// again, so the operation ends here and the person decides again, under a
/// new operation. Using [ApiException.isDefinitiveRefusal] here would resend
/// a refused body for ever (upload_manager_review_answers_test, "422
/// tag_write_unsupported (retryable) is a refusal"; delete_jobs_submit_test,
/// "a refusal is final").
///
/// 401 is a wait for sign-in ([isUnauthorized]); 408 and 429 say "later".
SubmissionFailureDisposition? refusalIsFinal(Object error) =>
    error is ApiException &&
        error.statusCode >= 400 &&
        error.statusCode <= 499 &&
        !const {401, 408, 429}.contains(error.statusCode)
    ? SubmissionTerminal(error.errorCode ?? 'http_${error.statusCode}')
    : null;

/// A 401 answer: a wait for sign-in, never a refusal or a failure.
bool isUnauthorized(Object cause) =>
    cause is ApiException && cause.statusCode == 401;

/// A failed status query of a submission, so its failure hook can tell it
/// from a failed send: a failed status query never settles an operation as
/// refused.
class StatusQueryFailed implements Exception {
  const StatusQueryFailed(this.cause);
  final Object cause;
}
