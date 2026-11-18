// What the Uploads page shows (spec §7 para 3), computed from the local
// upload intents, the running transfers' progress and whether network work
// is possible. Pure model code: the rules for which action an item offers in
// which state, and when network actions are off, live here (SC-26).
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/services/download_manager.dart' show formatBytes;
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';

const _inProgress = {
  'allocating',
  'allocated',
  'transferring',
  'receiving',
  'validating',
  'committing',
  'review_submitted',
  'cancelling',
};
const _done = {'imported', 'duplicate', 'expanded'};
/// States of an adopted row that read as sent by another device while its
/// upload's files are seen arriving (besides `receiving`, always).
const _otherDeviceWaiting = {'on_other_device', 'allocated', 'transferring'};
/// Failed, refused, or waiting for the user.
const uploadAttentionStates = {
  'failed',
  'rejected',
  'needs_reselect',
  'source_changed',
  'duplicate_conflict',
  'on_other_device',
};
const _cancellable = {
  'allocating',
  'allocated',
  'transferring',
  'receiving',
  'validating',
  'review_ready',
  'failed',
  'duplicate_conflict',
  'source_changed',
  'needs_reselect',
  'rejected',
  'on_other_device',
};

/// Whether this session can do network upload work right now.
enum UploadsAvailability {
  available,

  /// Offline: cached statuses only.
  offline,

  /// A different server or signed out: network features are paused.
  serverBlocked,

  /// The server hasn't answered on this connection yet (cached block or
  /// still loading).
  cachedOnly,

  /// The server doesn't offer uploads.
  notAdvertised,
}

/// Blocked wins over offline, offline over the feature block's state.
UploadsAvailability uploadsAvailability({
  required bool offline,
  required ServerBlockedReason blocked,
  required AdvertisedFeature<UploadsFeature>? feature,
  bool featureLoading = false,
}) {
  if (blocked != ServerBlockedReason.none) {
    return UploadsAvailability.serverBlocked;
  }
  if (offline) return UploadsAvailability.offline;
  if (featureLoading || (feature != null && feature.fromCache)) {
    return UploadsAvailability.cachedOnly;
  }
  return feature == null
      ? UploadsAvailability.notAdvertised
      : UploadsAvailability.available;
}

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
    (state == 'review_ready' && !isServerRefusedReview(state, errorCode)) ||
    state == 'duplicate_conflict';

/// Whether an item in [state] is failed, refused, or waiting for the user.
bool needsUserAttention(String state, String? errorCode) =>
    uploadAttentionStates.contains(state) ||
    isServerRefusedReview(state, errorCode);

/// One item row.
class UploadRow {
  const UploadRow({
    required this.itemUuid,
    required this.batchUuid,
    required this.displayName,
    required this.statusText,
    required this.detailText,
    required this.sizeText,
    required this.sending,
    required this.sentBytes,
    required this.totalBytes,
    required this.needsAttention,
    required this.offersCancel,
    required this.offersReselect,
    required this.offersReviewTags,
    required this.offersChildren,
    required this.canCancel,
    required this.canReselect,
    required this.canReviewTags,
    required this.canOpenChildren,
    required this.offersRetry,
    required this.canRetry,
  });

  /// A failed item the server will retry (see [serverRetryableCodes]).
  final bool offersRetry;
  final bool canRetry;

  final String itemUuid;
  final String batchUuid;
  final String displayName;
  final String statusText;
  final String? detailText;

  /// "3.0 MB of 10.0 MB" while sending, the size otherwise; null when the
  /// size is unknown and nothing is being sent.
  final String? sizeText;

  /// Bytes are on their way (show a progress bar).
  final bool sending;

  /// Null: unknown (not sending, or no progress reported yet).
  final int? sentBytes;

  /// Null: unknown.
  final int? totalBytes;

  /// Failed, refused, or waiting for the user.
  final bool needsAttention;

  final bool canCancel;

  /// "Reselect file to retry".
  final bool canReselect;
  final bool canReviewTags;

  /// An unpacked ZIP: its files can be listed.
  final bool canOpenChildren;

  /// The item's state offers the action (whatever the network): the page
  /// shows it, enabled by the matching `can…`.
  final bool offersCancel;
  final bool offersReselect;
  final bool offersReviewTags;
  final bool offersChildren;

  /// Sent / total in 0..1; null when either is unknown.
  double? get fraction {
    final sent = sentBytes, total = totalBytes;
    if (sent == null || total == null || total <= 0) return null;
    return (sent / total).clamp(0.0, 1.0);
  }
}

/// How many items are in each group.
class UploadCounts {
  const UploadCounts({
    required this.total,
    required this.inProgress,
    required this.readyForReview,
    required this.needsAttention,
    required this.done,
    required this.cancelled,
    required this.expired,
  });

  final int total;
  final int inProgress;
  final int readyForReview;
  final int needsAttention;
  final int done;
  final int cancelled;
  final int expired;

  /// "5 files · 2 in progress · 1 done"; empty groups left out.
  String get summaryText => [
    '$total ${total == 1 ? 'file' : 'files'}',
    if (inProgress > 0) '$inProgress in progress',
    if (readyForReview > 0) '$readyForReview ready for review',
    if (needsAttention > 0)
      '$needsAttention ${needsAttention == 1 ? 'needs' : 'need'} attention',
    if (done > 0) '$done done',
    if (cancelled > 0) '$cancelled cancelled',
    if (expired > 0) '$expired expired',
  ].join(' · ');
}

class UploadsOverview {
  const UploadsOverview({
    required this.availability,
    required this.rows,
    required this.counts,
    required this.limitsText,
  });

  /// [intents] in display order; [progress] = bytes sent per running item.
  factory UploadsOverview.of({
    required List<UploadIntentRecord> intents,
    required Map<String, int> progress,
    required UploadsAvailability availability,
    UploadLimits? limits,

    /// The server's per-item `retryable` flag (SC-22), by item UUID.
    Map<String, bool> retryable = const {},
    /// The batches another device is sending (the upload manager's).
    Set<String> otherDeviceSending = const {},

    /// Nothing can move now although the page is available (e.g. the server
    /// check failed): rows read Paused.
    bool transfersPaused = false,
  }) {
    // Children are listed under their archive elsewhere.
    final top = [
      for (final i in intents)
        if (i.parentItemUuid == null) i,
    ];
    final online =
        availability == UploadsAvailability.available && !transfersPaused;
    final rows = [
      for (final i in top)
        _row(
          i,
          progress[i.itemUuid],
          retryable[i.itemUuid],
          online: online,
          otherDeviceSending: otherDeviceSending,
        ),
    ];
    int count(bool Function(String) test) =>
        top.where((i) => test(i.lastState)).length;
    final maxFiles = limits?.maxFilesPerBatch;
    final maxBytes = limits?.maxFileBytes;
    return UploadsOverview(
      availability: availability,
      rows: rows,
      counts: UploadCounts(
        total: top.length,
        inProgress: count(_inProgress.contains),
        readyForReview: top
            .where((i) =>
                i.lastState == 'review_ready' &&
                !isServerRefusedReview(i.lastState, i.lastErrorCode))
            .length,
        needsAttention: rows.where((r) => r.needsAttention).length,
        done: count(_done.contains),
        cancelled: count((s) => s == 'cancelled'),
        expired: count((s) => s == 'expired'),
      ),
      limitsText: switch ((maxFiles, maxBytes)) {
        (null, null) => null,
        (final f?, null) => 'Up to $f files at a time',
        (null, final b?) => 'Each file up to ${formatBytes(b)}',
        (final f?, final b?) =>
          'Up to $f files at a time, each up to ${formatBytes(b)}',
      },
    );
  }

  static UploadRow _row(
    UploadIntentRecord i,
    int? progressBytes,
    bool? serverRetryable, {
    required bool online,
    required Set<String> otherDeviceSending,
  }) {
    final state = i.lastState;
    // An adopted row whose bytes another device is sending (sign-off
    // s7-app-texts): the server receiving them, or this device saw its
    // upload's files arrive lately (UploadArrivals). Without network nothing
    // is known to move: the row reads as its stored state (Paused).
    final fromOtherDevice =
        online &&
        !i.bytesOnThisDevice &&
        (state == 'receiving' ||
            (_otherDeviceWaiting.contains(state) &&
                otherDeviceSending.contains(i.batchUuid)));
    // Without network nothing is moving, whatever state was last stored.
    final sending = online && (state == 'transferring' || state == 'receiving');
    final sent = sending ? progressBytes : null;
    final total = i.expectedLength;
    final offersCancel = _cancellable.contains(state);
    final offersReselect = state == 'needs_reselect' || state == 'source_changed';
    final offersReviewTags = offersReview(state, i.lastErrorCode);
    final offersChildren = state == 'expanded';
    // The server's Retry of a lost received file waits for the bytes again,
    // which this device can't send without them (review r1 #2).
    final needsBytesHere = i.lastErrorCode == 'upload_source_missing';
    final offersRetry =
        state == 'failed' &&
        (serverRetryable ?? serverRetryableCodes.contains(i.lastErrorCode)) &&
        (!needsBytesHere || i.bytesOnThisDevice);
    return UploadRow(
      itemUuid: i.itemUuid,
      batchUuid: i.batchUuid,
      displayName: i.displayName,
      // Only the row being received is uploading; a waiting one still waits.
      statusText: fromOtherDevice && state == 'receiving'
          ? otherDeviceSendingStatus
          : uploadStatusText(
              state,
              errorCode: i.lastErrorCode,
              paused: !online,
            ),
      detailText: fromOtherDevice
          ? otherDeviceSendingText
          : uploadDetailText(
              state,
              errorCode: i.lastErrorCode,
              bytesHere: i.bytesOnThisDevice,
            ),
      sizeText: switch ((sent, total)) {
        (final s?, final t?) => '${formatBytes(s)} of ${formatBytes(t)}',
        (final s?, null) => '${formatBytes(s)} sent',
        (null, final t?) => formatBytes(t),
        _ => null,
      },
      sending: sending,
      sentBytes: sent,
      totalBytes: total,
      needsAttention:
          !fromOtherDevice && needsUserAttention(state, i.lastErrorCode),
      offersCancel: offersCancel,
      offersReselect: offersReselect,
      offersReviewTags: offersReviewTags,
      offersChildren: offersChildren,
      canCancel: offersCancel && online,
      canReselect: offersReselect && online,
      canReviewTags: offersReviewTags && online,
      canOpenChildren: offersChildren && online,
      offersRetry: offersRetry,
      canRetry: offersRetry && online,
    );
  }

  final UploadsAvailability availability;
  final List<UploadRow> rows;
  final UploadCounts counts;

  /// "Up to 100 files at a time, each up to 250.0 MB"; only the known
  /// limits; null when none is known.
  final String? limitsText;

  bool get canAddFiles => networkActionsEnabled;

  /// Network actions (send, cancel, review, list an archive) are on.
  bool get networkActionsEnabled =>
      availability == UploadsAvailability.available;

  /// Why network actions are off (the disabled actions' explanation), or
  /// null when they are on.
  String? get unavailableText => switch (availability) {
    UploadsAvailability.available => null,
    UploadsAvailability.offline => 'Unavailable while offline',
    UploadsAvailability.serverBlocked =>
      'Unavailable while network features are paused',
    UploadsAvailability.cachedOnly => 'Waiting for the server to answer',
    UploadsAvailability.notAdvertised => "This server doesn't offer uploads",
  };
}
