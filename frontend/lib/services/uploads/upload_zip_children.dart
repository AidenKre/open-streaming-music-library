// The files of an unpacked ZIP (spec §7 para 3: "Expanded ZIP parent opens
// its child list with valid/failed/skipped counts"). A read-only projection
// over the server's item pages (the upload manager keeps no intents for ZIP
// children); the API call waits for a server check in flight only within
// the binding gate's bound, never without a limit. Model code: nothing from
// ui/.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart'
    show isServerRefusedReview, needsUserAttention, offersReview;
import 'package:frontend/services/uploads/upload_status_text.dart';

const _validStates = {
  'review_ready',
  'committing',
  'imported',
  'duplicate',
  'duplicate_conflict',
};

/// One file inside the archive.
class UploadChildRow {
  const UploadChildRow({
    required this.itemUuid,
    required this.displayName,
    required this.statusText,
    required this.detailText,
    required this.needsAttention,
    this.offersReviewTags = false,
  });

  /// The file is ready for review.
  final bool offersReviewTags;
  final String itemUuid;
  final String displayName;
  final String statusText;
  final String? detailText;
  final bool needsAttention;
}

/// The archive's files in the server's order, and their outcome counts.
class ZipChildren {
  const ZipChildren({
    required this.children,
    required this.valid,
    required this.failed,
    required this.checking,
    required this.cancelled,
    required this.skipped,
  });

  final List<UploadChildRow> children;

  /// Passed validation (ready for review, importing, imported, duplicate,
  /// or waiting for a duplicate decision).
  final int valid;
  final int failed;

  /// Not validated yet.
  final int checking;

  /// Cancelled or expired.
  final int cancelled;

  /// Non-audio entries the server ignored, from the archive item's
  /// `skipped_members`; null = unknown (not reported or the archive item
  /// wasn't listed), which shows nothing.
  final int? skipped;

  /// "3 valid · 1 failed · 2 skipped"; empty groups except valid and
  /// failed left out; an unknown skipped count is left out.
  String get countsText => [
    '$valid valid',
    '$failed failed',
    if (skipped != null) '$skipped skipped',
    if (checking > 0) '$checking still checking',
    if (cancelled > 0) '$cancelled cancelled',
  ].join(' · ');
}

class UploadZipChildren {
  UploadZipChildren(this._api);
  final UploadsApi _api;

  /// Every page of [batchUuid]'s items, keeping [parentItemUuid]'s
  /// children in server order. Errors reach the caller.
  Future<ZipChildren> load(String batchUuid, String parentItemUuid) async {
    final children = <UploadChildRow>[];
    var valid = 0, failed = 0, checking = 0, cancelled = 0;
    final seen = <String>{};
    int? skipped;
    String? cursor;
    do {
      // A page a person is looking at: like the person's own action, it
      // waits for a server check only within the gate's bound, and fails at
      // once on a different server, signed out, or offline with the server
      // still verified (row 72).
      final page = await _api.listItems(
        batchUuid,
        after: cursor,
        limit: 100,
        wait: BindingWait.forPendingVerdict,
      );
      for (final item in page.items) {
        if (item.itemUuid == parentItemUuid) skipped = item.skippedMembers;
        if (item.parentItemUuid != parentItemUuid) continue;
        final state = item.rawState;
        final code = item.error?.code;
        children.add(
          UploadChildRow(
            itemUuid: item.itemUuid,
            displayName: item.filename,
            statusText: uploadStatusText(state, errorCode: code),
            detailText: uploadDetailText(
              state,
              errorCode: code,
              fromArchive: true,
            ),
            needsAttention: needsUserAttention(state, code),
            offersReviewTags: offersReview(state, code),
          ),
        );
        if (isServerRefusedReview(state, code)) {
          failed++;
        } else if (_validStates.contains(state)) {
          valid++;
        } else if (state == 'failed') {
          failed++;
        } else if (state == 'cancelled' || state == 'expired') {
          cancelled++;
        } else {
          checking++;
        }
      }
      cursor = page.nextAfter;
      // A repeated cursor would loop forever.
    } while (cursor != null && seen.add(cursor));
    return ZipChildren(
      children: children,
      valid: valid,
      failed: failed,
      checking: checking,
      cancelled: cancelled,
      skipped: skipped,
    );
  }
}

final uploadZipChildrenProvider = Provider<UploadZipChildren>(
  (ref) => UploadZipChildren(ref.read(uploadsApiProvider)),
);
