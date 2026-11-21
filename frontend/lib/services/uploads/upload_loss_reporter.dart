// What Disconnect and Log out would drop from the upload intents (DEV-7-22,
// DEV-8-14). Model code: nothing from ui/ (SC-26).
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_review.dart' show decodeDraft;

/// What one sign-in holds in the upload intents that Disconnect or Log out
/// would drop (DEV-7-22, DEV-8-14); see [UploadLossReporter.counts].
class UploadLossCounts {
  const UploadLossCounts({
    required this.unsent,
    required this.reviewDrafts,
    required this.unsentReviews,
    required this.unsentCancels,
  });

  /// Files whose bytes the server doesn't have yet (the Disconnect rule).
  final int unsent;

  /// Reviewable rows with a typed, unconfirmed tag draft.
  final int reviewDrafts;

  /// Reviews confirmed here that the server hasn't answered.
  final int unsentReviews;

  /// Cancels the server hasn't answered.
  final int unsentCancels;
}

/// The Disconnect confirmation's "unsent uploads" line: the files on this
/// device (kept ones of an ended sign-in included) whose bytes the server
/// doesn't have yet. [counts] is the one read of the intents; Log out reuses
/// it for its extra categories.
class UploadLossReporter implements LossReporter {
  UploadLossReporter({
    required UploadIntentStore intents,
    required ServerBindingRepository binding,
  }) : _intents = intents,
       _binding = binding;

  final UploadIntentStore _intents;
  final ServerBindingRepository _binding;

  /// The counts of every row on this device while a binding exists (rows kept
  /// by an ended sign-in included), or null with no binding. Throws when the
  /// binding or its intents cannot be read.
  Future<UploadLossCounts?> counts() async {
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return null;
    var unsent = 0, drafts = 0, reviews = 0, cancels = 0;
    for (final i in await _intents.all()) {
      final state = i.lastState;
      if (i.bytesOnThisDevice && unsentStates.contains(state)) unsent++;
      if (reviewableStates.contains(state) &&
          decodeDraft(i.draftJson).isNotEmpty) {
        drafts++;
      }
      if (state == UploadIntentState.reviewSubmitted) reviews++;
      if (state == UploadIntentState.cancelling) cancels++;
    }
    return UploadLossCounts(
      unsent: unsent,
      reviewDrafts: drafts,
      unsentReviews: reviews,
      unsentCancels: cancels,
    );
  }

  @override
  Future<String?> pendingLossSummary() async {
    final c = await counts();
    final count = c?.unsent ?? 0;
    return switch (count) {
      0 => null,
      1 => '1 upload not yet sent',
      _ => '$count uploads not yet sent',
    };
  }
}
