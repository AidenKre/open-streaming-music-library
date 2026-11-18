// Pure review rules (spec §7 para 4): what a review row offers, when the
// review advances, and when newly ready items are announced. No I/O; nothing
// from ui/.
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart'
    show
        isServerRefusedReview,
        offersReview,
        reviewableStates,
        sentFromOtherDevice;
import 'package:frontend/services/uploads/upload_status_text.dart';

/// The order of reads of review items: the newest-started read of an item
/// wins, whichever kind it is (a re-read or a snapshot). One counter serves
/// every read.
class ReviewReadOrder {
  int _last = 0;
  final _accepted = <String, int>{};
  int _acceptedSnapshot = 0;

  /// True, recording [ticket], when it is newer than the last accepted
  /// snapshot; an older snapshot landing late must not undo the review's
  /// membership and order.
  bool acceptSnapshot(int ticket) {
    if (ticket <= _acceptedSnapshot) return false;
    _acceptedSnapshot = ticket;
    return true;
  }

  /// Call when a read starts; the ticket is passed to [accept] when it lands.
  int begin() => ++_last;

  /// True, recording [ticket], when it is newer than the last accepted for
  /// [itemUuid]; false when a newer read already landed.
  bool accept(String itemUuid, int ticket) {
    if (ticket <= (_accepted[itemUuid] ?? 0)) return false;
    _accepted[itemUuid] = ticket;
    return true;
  }
}

const _inFlight = {'review_submitted', 'committing'};
const _reviewResolved = {'imported', 'duplicate'};

/// One item of the review as the page shows it. The local intent, when there
/// is one, is the live mirror and wins for state and error code. "On submit
/// disable duplicate action ... a failed item stays reviewable."
class ReviewItemView {
  const ReviewItemView._({
    required this.itemUuid,
    required this.reviewVersion,
    required this.displayName,
    required this.statusText,
    required this.errorText,
    required this.reviewable,
    required this.inFlight,
    required this.done,
    required this.canConfirm,
    required this.canSkip,
    required this.canCancel,
    required this.canPreview,
    required this.tagWriteSupported,
    required this.resultTrackUuid,
    required this.duplicates,
    required this.conflict,
    required this.canDecideDuplicates,
    required this.useExistingTrackUuid,
    required this.dontImportTrackUuid,
    required this.canBackToReview,
    required this.canPlayExisting,
  });

  factory ReviewItemView.of({
    required UploadItem item,
    UploadIntentRecord? intent,
    required bool online,
    Set<DuplicateGroup> chosen = const {},
    Set<String> otherDeviceSending = const {},
    bool transfersPaused = false,
  }) {
    final state = intent?.lastState ?? item.rawState;
    final code = intent != null ? intent.lastErrorCode : item.error?.code;
    final reviewable = state == 'review_ready';
    final cancellable = reviewableStates.contains(state) && online;
    final duplicates = DuplicateBanners.of(item, chosen: chosen);
    final conflict = state == 'duplicate_conflict'
        ? DuplicateConflictView.of(item)
        : null;
    final canAct = reviewable && online;
    final canConfirm = canAct && !isServerRefusedReview(state, code);
    // The texts follow the Uploads page: the same other-device check, and
    // nothing moves while transfers are paused.
    final bytesHere = intent?.bytesOnThisDevice ?? false;
    final moving = online && !transfersPaused;
    final texts = uploadItemTexts(
      state,
      errorCode: code,
      bytesHere: bytesHere,
      paused: !moving,
      fromArchive: item.parentItemUuid != null,
      fromOtherDevice: sentFromOtherDevice(
        state,
        bytesHere: bytesHere,
        online: moving,
        batchSending: otherDeviceSending.contains(item.batchUuid),
      ),
    );
    return ReviewItemView._(
      itemUuid: item.itemUuid,
      reviewVersion: item.reviewVersion,
      displayName: item.filename,
      statusText: texts.status,
      errorText: texts.detail,
      reviewable: reviewable,
      inFlight: _inFlight.contains(state),
      done: _reviewResolved.contains(state),
      canConfirm: canConfirm && !duplicates.needsChoice,
      canSkip: canConfirm && !duplicates.needsChoice,
      canCancel: cancellable,
      canPreview: reviewable && online,
      tagWriteSupported: item.tagWriteSupported,
      resultTrackUuid: item.resultTrackUuid,
      duplicates: duplicates,
      conflict: conflict,
      canDecideDuplicates: canAct,
      useExistingTrackUuid: canAct
          ? duplicates.useExistingTrackUuid
          : (conflict != null && online ? conflict.useExistingTrackUuid : null),
      dontImportTrackUuid: canAct ? duplicates.dontImportTrackUuid : null,
      canBackToReview: state == 'duplicate_conflict' && online,
      canPlayExisting: online && reviewableStates.contains(state),
    );
  }

  final String itemUuid;
  final int reviewVersion;
  final String displayName;
  final String statusText;
  final String? errorText;
  final bool reviewable;
  final bool inFlight;
  final bool done;
  final bool canConfirm;
  final bool canSkip;
  final bool canCancel;
  final bool canPreview;
  final bool? tagWriteSupported;
  final String? resultTrackUuid;

  final DuplicateBanners duplicates;
  final DuplicateConflictView? conflict;
  final bool canDecideDuplicates;
  final String? useExistingTrackUuid;
  final String? dontImportTrackUuid;
  final bool canBackToReview;

  final bool canPlayExisting;
}

/// "Advance only after durable imported/duplicate result": true when [after]
/// is such a result and [before] is known and was not one already.
bool reviewAdvances({required String? before, required String after}) =>
    _reviewResolved.contains(after) &&
    before != null &&
    !_reviewResolved.contains(before);

/// "New arriving ready items appear through More items ready - Refresh":
/// some intent of [batchUuid] is ready and not in the [snapshot].
bool moreItemsReady({
  required Set<String> snapshot,
  required String batchUuid,
  required Iterable<UploadIntentRecord> intents,
}) => intents.any(
  (i) =>
      i.batchUuid == batchUuid &&
      i.lastState == 'review_ready' &&
      offersReview(i.lastState, i.lastErrorCode) &&
      !snapshot.contains(i.itemUuid),
);

/// Whether [source] is the preview playing now (or still loading, so it can
/// be stopped): one rule for every Play / Pause toggle of the review.
bool previewPlaying(PreviewState state, PreviewSource source) =>
    state.source == source && previewIsActive(state.status);
