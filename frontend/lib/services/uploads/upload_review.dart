// The review model (spec §7 para 4; §4 commit): the batch's ready-item
// snapshot over every page, per-item drafts kept in the local intent, and
// the Confirm / Skip / Cancel sends. Model code: nothing from ui/.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';

/// `{"v":1,"edits":{key: value}}`; a null value is an explicit clear.
String encodeDraft(MetadataEdit edit) =>
    jsonEncode({'v': 1, 'edits': edit.toPayload()});

/// The draft in [json], or no edits when it is absent, malformed or of the
/// wrong shape. Keys that are not editable fields are dropped.
MetadataEdit decodeDraft(String? json) {
  if (json == null) return const MetadataEdit.empty();
  try {
    final m = jsonDecode(json);
    if (m is! Map || m['v'] != 1 || m['edits'] is! Map) {
      return const MetadataEdit.empty();
    }
    var edit = const MetadataEdit.empty();
    for (final MapEntry(:key, :value) in (m['edits'] as Map).entries) {
      if (key is String && editableMetadataColumns.contains(key)) {
        edit = edit.set(key, value);
      }
    }
    return edit;
  } catch (_) {
    return const MetadataEdit.empty();
  }
}

class UploadReview {
  UploadReview({
    required UploadsApi api,
    required UploadIntentStore intents,
    required ServerBindingRepository binding,
    required UploadManager manager,
    required UploadDuplicateDecisions decisions,
    Future<List<String>> Function(String key, String query)? suggest,
  }) : _suggest = suggest ?? ((_, _) async => const []),
       _api = api,
       _intents = intents,
       _binding = binding,
       _manager = manager,
       _decisions = decisions;

  final UploadsApi _api;
  final UploadIntentStore _intents;
  final ServerBindingRepository _binding;
  final UploadManager _manager;
  final UploadDuplicateDecisions _decisions;
  final Future<List<String>> Function(String key, String query) _suggest;

  Future<String> _token() async {
    final token = (await _binding.current())?.localBindingId;
    if (token == null) throw const UploadsUnavailable();
    return token;
  }

  /// The batch's items that are `review_ready` or `duplicate_conflict` (both
  /// need a decision) or in [keep], in the server's order, over every page.
  /// Listed ZIP children of a local archive get a
  /// local intent on the way, and every listed item's fresh state is mirrored
  /// into its local review intent (see `mirrorReviewStates`).
  Future<List<UploadItem>> snapshot(
    String batchUuid, {
    Set<String> keep = const {},
  }) async {
    final token = await _token();
    final result = <UploadItem>[];
    String? cursor;
    do {
      final page = await _api.listItems(batchUuid, after: cursor);
      await _intents.adoptListedChildren(token, page.items);
      await _intents.mirrorReviewStates(token, page.items);
      for (final item in page.items) {
        if (item.rawState == 'review_ready' ||
            item.rawState == 'duplicate_conflict' ||
            keep.contains(item.itemUuid)) {
          result.add(item);
        }
      }
      cursor = page.nextAfter;
    } while (cursor != null);
    return result;
  }

  /// The item as the server has it now. A ready or conflicting item the
  /// server has since ended is mirrored into its local intent, so the review
  /// stops offering it; a submitted or committing intent is never overwritten.
  Future<UploadItem> item(String itemUuid) async {
    final item = await _api.getItem(itemUuid);
    final token = (await _binding.current())?.localBindingId;
    if (token != null) await _intents.mirrorReviewStates(token, [item]);
    return item;
  }

  Future<MetadataEdit> draftOf(String itemUuid) async {
    final token = await _token();
    final intent = (await _intents.forBinding(
      token,
    )).where((i) => i.itemUuid == itemUuid).firstOrNull;
    return decodeDraft(intent?.draftJson);
  }

  /// Stores the draft locally; nothing is sent and no version changes.
  Future<void> saveDraft(String itemUuid, MetadataEdit edit) async =>
      _intents.update(
        await _token(),
        [itemUuid],
        draftJson: Value(encodeDraft(edit)),
      );

  Future<void> confirm(
    UploadItem item,
    MetadataEdit edits, {
    required bool writeTags,
  }) => _send(item, edits.toPayload(), writeTags);

  /// Imports as is: empty edits, no tag writing; the draft is ignored.
  Future<void> skip(UploadItem item) => _send(item, const {}, false);

  Future<void> _send(
    UploadItem item,
    Map<String, Object?> edits,
    bool writeTags,
  ) => _manager.submitReviewAction(
    item.itemUuid,
    ReviewActionKind.commit,
    reviewVersion: item.reviewVersion,
    body: CommitBody(
      baseReviewVersion: item.reviewVersion,
      edits: edits,
      writeTags: writeTags,
      acknowledged: _decisions.acknowledgementsFor(item),
    ).toJson(),
  );

  Future<void> cancel(String itemUuid) => _manager.cancel(itemUuid);

  /// Import as separate track / Import both.
  void chooseDuplicates(UploadItem item, DuplicateGroup group) =>
      _decisions.choose(item, group);

  Set<DuplicateGroup> chosenDuplicates(UploadItem item) =>
      _decisions.chosenFor(item);

  /// Use existing track / Don't import: closes the item as a duplicate of
  /// [trackUuid].
  Future<void> resolveDuplicate(UploadItem item, String trackUuid) =>
      _manager.submitReviewAction(
        item.itemUuid,
        ReviewActionKind.resolveDuplicate,
        reviewVersion: item.reviewVersion,
        body: ResolveDuplicateBody(
          expectedReviewVersion: item.reviewVersion,
          existingTrackUuid: trackUuid,
        ).toJson(),
      );

  /// Back to review: the server re-checks the item.
  Future<RetryOutcome> backToReview(String itemUuid) =>
      _manager.retry(itemUuid);

  /// Values already used for [key] that start with [query] (local cache).
  Future<List<String>> suggestions(String key, String query) =>
      _suggest(key, query);
}

/// The imported track as the local library holds it (null until synced).
final uploadedTrackProvider = StreamProvider.autoDispose
    .family<TrackUI?, String>(
      (ref, uuid) => ref.watch(browseRepositoryProvider).watchTrack(uuid),
    );

final uploadReviewProvider = Provider<UploadReview>(
  (ref) => UploadReview(
    api: ref.read(uploadsApiProvider),
    intents: ref.read(uploadIntentStoreProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    manager: ref.read(uploadManagerProvider),
    decisions: ref.read(uploadDuplicateDecisionsProvider),
    suggest: ref.read(editOutboxProvider).fieldSuggestions,
  ),
);
