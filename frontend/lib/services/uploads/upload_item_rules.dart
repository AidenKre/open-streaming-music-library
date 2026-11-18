// The upload item states and the shared rules over them (spec §7): the
// server's item states, the local intent states, the sets several places
// agree on, and the attention and review predicates. Pure model code: raw
// strings, no I/O, nothing from ui/ (SC-26).

/// The server's item states (an upload item's `state`).
abstract final class ServerItemState {
  static const allocated = 'allocated';
  static const receiving = 'receiving';
  static const validating = 'validating';
  static const reviewReady = 'review_ready';
  static const committing = 'committing';
  static const imported = 'imported';
  static const duplicate = 'duplicate';
  static const expanded = 'expanded';
  static const failed = 'failed';
  static const duplicateConflict = 'duplicate_conflict';
  static const expired = 'expired';
  static const cancelled = 'cancelled';
}

/// The local states an upload intent's `last_state` holds besides the
/// server's own item states.
abstract final class UploadIntentState {
  static const allocating = 'allocating';
  static const allocated = 'allocated';
  static const transferring = 'transferring';
  static const sourceChanged = 'source_changed';
  static const needsReselect = 'needs_reselect';
  static const rejected = 'rejected';
  static const cancelling = 'cancelling';
  static const reviewSubmitted = 'review_submitted';

  /// An adopted item that still needs its bytes: they are on the device it
  /// was picked on, never sent from here (7-R1-22). Cancel only.
  static const onOtherDevice = 'on_other_device';

  /// The server states in which an item still needs its bytes.
  static const awaitingBytes = {allocated, transferring};
}

/// Ended item states: nothing is left to do.
const endedStates = {
  ServerItemState.imported,
  ServerItemState.duplicate,
  ServerItemState.cancelled,
  ServerItemState.expired,
};

/// The item needs a decision in the review.
const reviewableStates = {
  ServerItemState.reviewReady,
  ServerItemState.duplicateConflict,
};

/// States of an adopted row that read as sent by another device while its
/// upload's files are seen arriving (besides `receiving`, always).
const otherDeviceWaitingStates = {
  UploadIntentState.onOtherDevice,
  ServerItemState.allocated,
  UploadIntentState.transferring,
};

/// Whether an item in [state] reads as sent by another device (sign-off
/// s7-app-texts): an adopted row ([bytesHere] false) the server is
/// receiving, or one still waiting while this device sees its upload's
/// files arrive lately ([batchSending], from UploadArrivals). Without
/// network ([online] false) nothing is known to move: the row reads as its
/// stored state (Paused). One rule for the Uploads page and the review.
bool sentFromOtherDevice(
  String state, {
  required bool bytesHere,
  required bool online,
  required bool batchSending,
}) =>
    online &&
    !bytesHere &&
    (state == ServerItemState.receiving ||
        (otherDeviceWaitingStates.contains(state) && batchSending));

/// Failed, refused, or waiting for the user.
const uploadAttentionStates = {
  'failed',
  'rejected',
  'needs_reselect',
  'source_changed',
  'duplicate_conflict',
  'on_other_device',
};

/// The fallback for a `failed` item the server retries (7A.2c), used only
/// while the server's own per-item `retryable` flag is unknown (SC-22).
const serverRetryableCodes = {
  'probe_timeout',
  'probe_unavailable',
  'upload_source_missing',
  'upload_validation_failed',
  'user_staged_quota_exceeded',
  'staged_quota_exceeded',
  'insufficient_storage',
  'free_space_unknown',
  'upload_write_failed',
};

/// The error codes of a `review_ready` item the server will refuse again, so
/// the user cannot fix it by confirming (7-R1-UI-01): it is shown as not
/// importable, needs attention, and offers only Cancel.
const serverRefusedReviewCodes = {'upload_library_links_unsupported'};

/// True for a `review_ready` item carrying a [serverRefusedReviewCodes] code.
bool isServerRefusedReview(String state, String? errorCode) =>
    state == 'review_ready' && serverRefusedReviewCodes.contains(errorCode);

/// Whether an item in [state] can be reviewed: ready and not refused, or a
/// duplicate conflict. One rule for Uploads rows, ZIP children and counts.
bool offersReview(String state, String? errorCode) =>
    reviewableStates.contains(state) && !isServerRefusedReview(state, errorCode);

/// Whether an item in [state] is failed, refused, or waiting for the user.
bool needsUserAttention(String state, String? errorCode) =>
    uploadAttentionStates.contains(state) ||
    isServerRefusedReview(state, errorCode);
