// The values the upload manager answers with (spec §7): why files were left
// out, what a reselect or retry came to, and the unavailable error. Pure
// model types: no I/O, nothing from ui/ (SC-26).
import 'package:frontend/api/api_client.dart' show ApiException;

/// Whether [error] says the server forgot the upload batch: it kept the
/// record for its retention time, then removed it.
bool isBatchForgotten(Object error) =>
    error is ApiException &&
    error.statusCode == 404 &&
    error.errorCode == 'upload_batch_not_found';

/// Uploads can't be added: the server doesn't advertise them, or the
/// session's binding is gone.
class UploadsUnavailable implements Exception {
  const UploadsUnavailable();
}

/// A review action names an item this device holds no upload record of:
/// nothing was frozen or sent.
class UploadIntentMissing implements Exception {
  const UploadIntentMissing();
}

/// Why a selected file was left out of the upload.
enum LeftOutReason { empty, tooLarge, unreadable, changedWhileReading }

class LeftOutFile {
  const LeftOutFile(this.displayName, this.reason);
  final String displayName;
  final LeftOutReason reason;
}

/// What `UploadManager.reselect` did.
enum ReselectOutcome { accepted, differentFile, unreadable, notNeeded }

class AddFilesResult {
  const AddFilesResult({required this.batchUuids, required this.leftOut});
  final List<String> batchUuids;
  final List<LeftOutFile> leftOut;
}

/// What `UploadManager.retry` came to.
enum RetryOutcome {
  /// The server took the retry; the item moved on.
  accepted,

  /// The item is not in a state the server retries; its real state is stored.
  notRetryable,

  /// The item changed since it was read (review version); its real state is
  /// stored.
  changed,
}
