import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_manager.dart';

/// What logging out would drop (DEV-7-22, DEV-8-14: the new local token
/// orphans the unsent uploads and deletions on this device, kept ones of an
/// ended sign-in included). Each count
/// is null when it could not be read: unknown is not zero.
class LogoutLosses {
  const LogoutLosses({
    required this.unsentUploads,
    required this.reviewDrafts,
    required this.unsentReviews,
    required this.unsentCancels,
    required this.unsentDeletions,
    required this.unconfirmedDeletions,
  });

  /// Nothing could be read.
  static const unknown = LogoutLosses(
    unsentUploads: null,
    reviewDrafts: null,
    unsentReviews: null,
    unsentCancels: null,
    unsentDeletions: null,
    unconfirmedDeletions: null,
  );

  final int? unsentUploads;
  final int? reviewDrafts;
  final int? unsentReviews;
  final int? unsentCancels;
  final int? unsentDeletions;
  final int? unconfirmedDeletions;

  /// Shown last when any count could not be read.
  static const uncountedSummary = 'Some unsent changes could not be counted.';

  List<int?> get _all => [
    unsentUploads,
    reviewDrafts,
    unsentReviews,
    unsentCancels,
    unsentDeletions,
    unconfirmedDeletions,
  ];

  /// True only when every count was read and is exactly 0.
  bool get isEmpty => _all.every((c) => c == 0);

  /// One short line per non-zero known count, then the
  /// uncounted line once if any count is unknown.
  List<String> get lines {
    final out = <String>[];
    void add(int? n, String Function(int n, bool one) text) {
      if (n != null && n > 0) out.add(text(n, n == 1));
    }

    add(
      unsentUploads,
      (n, one) =>
          one ? "1 upload that didn't finish" : "$n uploads that didn't finish",
    );
    add(
      reviewDrafts,
      (n, one) => one ? 'Tags typed for 1 upload' : 'Tags typed for $n uploads',
    );
    add(
      unsentReviews,
      (n, one) => one
          ? '1 upload confirmed in Review, not yet answered'
          : '$n uploads confirmed in Review, not yet answered',
    );
    add(
      unsentCancels,
      (n, one) =>
          one ? '1 upload being cancelled' : '$n uploads being cancelled',
    );
    add(
      unsentDeletions,
      (n, one) => one ? '1 track deletion' : '$n track deletions',
    );
    add(
      unconfirmedDeletions,
      (n, one) => one
          ? "1 track deletion the server hasn't confirmed"
          : "$n track deletions the server hasn't confirmed",
    );
    if (_all.any((c) => c == null)) out.add(uncountedSummary);
    return out;
  }
}

/// Counts [LogoutLosses] by reusing the Disconnect reporters' rules.
class LogoutLossCounter {
  LogoutLossCounter({
    required UploadLossReporter uploads,
    required DeleteJobsLossReporter deletions,
  }) : _uploads = uploads,
       _deletions = deletions;

  final UploadLossReporter _uploads;
  final DeleteJobsLossReporter _deletions;

  /// Never throws; a category that cannot be read is null.
  Future<LogoutLosses> count() async {
    // Null `up` = unreadable; no binding reads as all zero.
    UploadLossCounts? up;
    ({int neverSent, int maybeReceived})? del;
    try {
      up =
          await _uploads.counts() ??
          const UploadLossCounts(
            unsent: 0,
            reviewDrafts: 0,
            unsentReviews: 0,
            unsentCancels: 0,
          );
    } catch (_) {}
    try {
      del = await _deletions.pendingCounts();
    } catch (_) {}
    return LogoutLosses(
      unsentUploads: up?.unsent,
      unsentDeletions: del?.neverSent,
      reviewDrafts: up?.reviewDrafts,
      unsentReviews: up?.unsentReviews,
      unsentCancels: up?.unsentCancels,
      unconfirmedDeletions: del?.maybeReceived,
    );
  }
}

final logoutLossCounterProvider = Provider<LogoutLossCounter>((ref) {
  return LogoutLossCounter(
    uploads: UploadLossReporter(
      intents: ref.read(uploadIntentStoreProvider),
      binding: ref.read(serverBindingRepositoryProvider),
    ),
    deletions: DeleteJobsLossReporter(
      submissions: ref.read(durableSubmissionProvider),
      binding: ref.read(serverBindingRepositoryProvider),
    ),
  );
});
