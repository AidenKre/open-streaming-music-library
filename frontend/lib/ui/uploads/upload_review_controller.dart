// The review page's presentation state (spec §7 para 4; SC-26): holds what
// the page shows and calls the model; the rules come from
// upload_review_rules.dart.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart' show ApiException;
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/operations/durable_submission.dart'
    show SubmissionConflict;
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';
import 'package:frontend/services/uploads/upload_duplicate_summary.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/uploads_overview.dart'
    show UploadsOverview;
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/upload_status_text.dart'
    show retryOutcomeText;
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart' as rules;
import 'package:frontend/services/uploads/upload_review_rules.dart'
    show ReviewItemView;

enum ReviewLoad { loading, failed, ready }

class ReviewImported {
  const ReviewImported(
    this.displayName,
    this.track, {
    this.alreadyInLibrary = false,
  });

  /// Closed as a duplicate of a library track (nothing was imported).
  final bool alreadyInLibrary;
  final String displayName;
  final TrackUI? track;
}

abstract interface class UploadReviewControls implements Listenable {
  ReviewLoad get load;
  int get position;
  int get total;
  String get positionText;
  ReviewItemView? get current;
  MetadataEdit get edit;
  Object? detectedValue(String key);

  /// The editable fields the form shows (the server's, else the built-in
  /// list).
  List<FieldDescriptor> get fields;
  bool get busy;
  bool get canPrevious;
  bool get canNext;
  bool get moreItemsReady;
  TrackUI? get currentTrack;
  ReviewImported? get lastImported;
  String? get notice;

  Future<void> start(String batchUuid, {String? startAt});
  Future<void> next();
  Future<void> previous();
  void editChanged(MetadataEdit edit);
  Future<void> confirm({
    required String itemUuid,
    required int reviewVersion,
    required bool writeTags,
  });
  Future<void> skip();
  Future<void> cancelItem();
  Future<void> refresh();
  Future<List<String>> suggestions(String key, String query);
  void dismissNotice();
  void dispose();

  /// The batch duplicate summary over the snapshot (null while loading).
  DuplicateSummary? get duplicateSummary;

  /// Import as separate track ([DuplicateGroup.library]) / Import both
  /// ([DuplicateGroup.staged]).
  void chooseDuplicates(DuplicateGroup group);

  /// Use existing track (review banner or conflict view).
  Future<void> useExisting();

  /// Don't import (best fingerprint match).
  Future<void> dontImport();

  /// Back to review from a `duplicate_conflict`.
  Future<void> backToReview();
}

typedef UploadReviewControlsFactory = UploadReviewControls Function();

final uploadReviewControllerFactoryProvider =
    Provider<UploadReviewControlsFactory>(
      (ref) =>
          () => UploadReviewController(ref),
    );

class UploadReviewController extends ChangeNotifier
    implements UploadReviewControls {
  UploadReviewController(this._ref) {
    _subs.add(
      _ref.listen<UploadsOverview?>(uploadsOverviewProvider, (_, o) {
        _online = o?.networkActionsEnabled ?? false;
        _notify();
      }, fireImmediately: true),
    );
    _subs.add(_ref.listen(appInfoProvider, (_, _) => _notify()));
  }

  final Ref _ref;
  final _subs = <ProviderSubscription<Object?>>[];
  ProviderSubscription<Object?>? _intentsSub;
  bool _online = false;
  bool _disposed = false;

  String _batch = '';
  ReviewLoad _load = ReviewLoad.loading;
  var _items = <String, UploadItem>{};
  var _order = <String>[];
  int _position = 0;
  final _drafts = <String, MetadataEdit>{};
  var _intents = <UploadIntentRecord>[];
  final _lastStates = <String, String>{};
  final _trackWatches = <String>{};
  final _tracks = <String, TrackUI?>{};
  bool _busy = false;
  String? _notice;
  String? _importedName;
  String? _importedTrackUuid;
  bool _importedAlreadyInLibrary = false;
  String? _importedItemUuid;

  /// Items whose read after a state change failed; tried again on the next
  /// intent emission (no timer).
  final _pendingReads = <String>{};
  final _retrying = <String>{};

  UploadReview get _review => _ref.read(uploadReviewProvider);
  PreviewControls get _preview => _ref.read(previewControlsProvider);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  ReviewLoad get load => _load;
  @override
  int get position => _position;
  @override
  int get total => _order.length;
  @override
  String get positionText => total == 0 ? '' : '${_position + 1}/$total';
  String? get _currentUuid => _order.isEmpty ? null : _order[_position];
  UploadItem? get _currentItem => _items[_currentUuid];

  @override
  ReviewItemView? get current {
    final item = _currentItem;
    if (item == null) return null;
    return ReviewItemView.of(
      item: item,
      intent: _intents.where((i) => i.itemUuid == item.itemUuid).firstOrNull,
      online: _online,
      chosen: _review.chosenDuplicates(item),
    );
  }

  @override
  MetadataEdit get edit => _drafts[_currentUuid] ?? const MetadataEdit.empty();
  @override
  List<FieldDescriptor> get fields {
    final info = _ref.read(appInfoProvider).value;
    final list = info == null ? null : editableFieldsFor(info, 'track');
    return list == null || list.isEmpty ? defaultEditableTrackFields : list;
  }

  @override
  Object? detectedValue(String key) =>
      _currentItem?.detectedMetadata?.tags.valueOf(key);
  @override
  bool get busy => _busy;
  @override
  bool get canPrevious => _position > 0;
  @override
  bool get canNext => _position < _order.length - 1;
  @override
  bool get moreItemsReady => rules.moreItemsReady(
    snapshot: _items.keys.toSet(),
    batchUuid: _batch,
    intents: _intents,
  );
  @override
  TrackUI? get currentTrack {
    final uuid = _currentItem?.resultTrackUuid;
    return uuid != null && (current?.done ?? false) ? _tracks[uuid] : null;
  }

  @override
  ReviewImported? get lastImported => _importedName == null
      ? null
      : ReviewImported(
          _importedName!,
          _tracks[_importedTrackUuid],
          alreadyInLibrary: _importedAlreadyInLibrary,
        );
  @override
  String? get notice => _notice;

  @override
  Future<void> start(String batchUuid, {String? startAt}) async {
    _batch = batchUuid;
    _load = ReviewLoad.loading;
    _notify();
    try {
      final ticket = _reads.begin();
      final list = await _review.snapshot(batchUuid);
      if (_disposed) return;
      if (!_reads.acceptSnapshot(ticket)) {
        _notify();
        return;
      }
      _setItems(list, ticket);
      final at = startAt == null ? -1 : _order.indexOf(startAt);
      _position = at < 0 ? 0 : at;
      await _loadDraft(_currentUuid);
      if (_disposed) return;
      _load = ReviewLoad.ready;
      _intentsSub?.close();
      _intentsSub = _ref.listen<AsyncValue<List<UploadIntentRecord>>>(
        uploadIntentsProvider,
        (_, v) => _onIntents(v.value),
        fireImmediately: true,
      );
    } catch (_) {
      _load = ReviewLoad.failed;
    }
    _notify();
  }

  /// The snapshot sets the order and the membership; an item a newer read
  /// already replaced keeps that newer read ([_reads]).
  void _setItems(List<UploadItem> list, int ticket) {
    final old = _items;
    _items = {};
    for (final i in list) {
      if (_reads.accept(i.itemUuid, ticket)) {
        _items[i.itemUuid] = i;
        // Just read: nothing left to retry, and the note's track is known.
        _pendingReads.remove(i.itemUuid);
        if (i.itemUuid == _importedItemUuid) {
          _importedTrackUuid = i.resultTrackUuid;
        }
      } else {
        _items[i.itemUuid] = old[i.itemUuid] ?? i;
      }
    }
    _order = [for (final i in list) i.itemUuid];
    list.forEach(_watchTrack);
  }

  void _watchTrack(UploadItem item) {
    final uuid = item.resultTrackUuid;
    if (uuid == null || !_trackWatches.add(uuid)) return;
    _subs.add(
      _ref.listen<AsyncValue<TrackUI?>>(uploadedTrackProvider(uuid), (_, v) {
        _tracks[uuid] = v.value;
        _notify();
      }, fireImmediately: true),
    );
  }

  /// Loads [uuid]'s draft once; a draft that cannot be read is no edits.
  Future<void> _loadDraft(String? uuid) async {
    if (uuid == null || _drafts.containsKey(uuid)) return;
    try {
      _drafts[uuid] = await _review.draftOf(uuid);
    } catch (_) {
      _drafts[uuid] = const MetadataEdit.empty();
    }
  }

  int _navigation = 0;

  /// Moves to [index]. The target's draft is loaded first (local), so the
  /// screen, the draft and a submit stay on the item shown until it is
  /// ready; a newer move makes an older one a no-op. The item is then
  /// refreshed in the background and never waits on the network (7-R1-20).
  Future<void> _goTo(int index) async {
    final generation = ++_navigation;
    final uuid = _order[index];
    // Started alongside the local draft load, never awaited: a gated or hung
    // read cannot hold the move. It only refreshes the item, never _position.
    unawaited(
      _reread(uuid).then((_) => _notify(), onError: (_) {
        // The item stays as last read.
      }),
    );
    await _loadDraft(uuid);
    final at = _order.indexOf(uuid);
    if (_disposed || generation != _navigation || at < 0) return;
    unawaited(_preview.close());
    _position = at;
    _notify();
  }

  final _reads = rules.ReviewReadOrder();

  Future<void> _reread(String uuid) async {
    final ticket = _reads.begin();
    final item = await _review.item(uuid);
    // An older read landing after a newer one never undoes it.
    if (_disposed || !_reads.accept(uuid, ticket)) return;
    _items[uuid] = item;
    if (uuid == _importedItemUuid) _importedTrackUuid = item.resultTrackUuid;
    _watchTrack(item);
  }

  @override
  Future<void> next() async {
    if (canNext) await _goTo(_position + 1);
  }

  @override
  Future<void> previous() async {
    if (canPrevious) await _goTo(_position - 1);
  }

  @override
  void editChanged(MetadataEdit edit) {
    final uuid = _currentUuid;
    if (uuid == null) return;
    _drafts[uuid] = edit;
    unawaited(_review.saveDraft(uuid, edit).catchError((_) {}));
    _notify();
  }

  void _onIntents(List<UploadIntentRecord>? list) {
    if (list == null) return;
    _intents = list;
    _notify();
    final changed = <String>{};
    for (final intent in list) {
      final before = _lastStates[intent.itemUuid];
      _lastStates[intent.itemUuid] = intent.lastState;
      if (before == null ||
          before == intent.lastState ||
          !_items.containsKey(intent.itemUuid)) {
        continue;
      }
      changed.add(intent.itemUuid);
      unawaited(_onChanged(intent.itemUuid, before, intent.lastState));
    }
    for (final uuid in _pendingReads.toList()) {
      if (!changed.contains(uuid)) unawaited(_retryRead(uuid));
    }
  }

  Future<void> _retryRead(String uuid) async {
    if (!_retrying.add(uuid)) return;
    try {
      await _reread(uuid);
      _pendingReads.remove(uuid);
      _notify();
    } catch (e) {
      // Stays pending for the next intent emission, unless the server
      // refuses the read for good.
      if (e is ApiException && e.isDefinitiveRefusal) {
        _pendingReads.remove(uuid);
      }
    } finally {
      _retrying.remove(uuid);
    }
  }

  Future<void> _onChanged(String uuid, String before, String after) async {
    try {
      await _reread(uuid);
      _pendingReads.remove(uuid);
    } catch (e) {
      // The import is durable on the server whether or not this read lands;
      // the read is tried again on the next intent emission, unless the
      // server refuses it for good.
      if (!(e is ApiException && e.isDefinitiveRefusal)) {
        _pendingReads.add(uuid);
      }
    }
    if (_disposed) return;
    final held = _items[uuid];
    if (held != null &&
        uuid == _currentUuid &&
        rules.reviewAdvances(before: before, after: after)) {
      _importedItemUuid = uuid;
      _importedName = held.filename;
      _importedTrackUuid = held.resultTrackUuid;
      _importedAlreadyInLibrary = after == 'duplicate';
      if (canNext) {
        await _goTo(_position + 1);
        return;
      }
    }
    _notify();
  }

  Future<void> _submit(
    bool Function(ReviewItemView) allowed,
    Future<void> Function(UploadItem) send,
  ) async {
    final view = current;
    final item = _currentItem;
    if (view == null || item == null || !allowed(view) || _busy) return;
    _busy = true;
    _notify();
    try {
      await send(item);
    } on SubmissionConflict {
      _notice = 'This file is already being imported.';
    } catch (_) {
      _notice = 'Something went wrong. Try again.';
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  Future<void> confirm({
    required String itemUuid,
    required int reviewVersion,
    required bool writeTags,
  }) => _submit(
    // Only the item and version the sheet was opened for (7-R1-01).
    (v) =>
        v.canConfirm &&
        v.itemUuid == itemUuid &&
        v.reviewVersion == reviewVersion,
    (item) => _review.confirm(item, edit, writeTags: writeTags),
  );

  @override
  Future<void> skip() => _submit((v) => v.canSkip, _review.skip);

  @override
  Future<void> cancelItem() async {
    final uuid = _currentUuid;
    if (uuid == null || !(current?.canCancel ?? false)) return;
    try {
      await _review.cancel(uuid);
    } catch (_) {
      _notice = 'Something went wrong. Try again.';
      _notify();
    }
  }

  @override
  Future<void> refresh() async {
    try {
      final keep = _items.keys.toSet();
      final ticket = _reads.begin();
      final list = await _review.snapshot(_batch, keep: keep);
      if (_disposed) return;
      if (!_reads.acceptSnapshot(ticket)) {
        _notify();
        return;
      }
      final uuid = _currentUuid;
      _setItems(list, ticket);
      final at = uuid == null ? -1 : _order.indexOf(uuid);
      _position = at < 0 ? 0 : at;
      if (_currentUuid != uuid) unawaited(_preview.close());
      await _loadDraft(_currentUuid);
    } catch (_) {
      _notice = 'Something went wrong. Try again.';
    }
    _notify();
  }

  @override
  Future<List<String>> suggestions(String key, String query) =>
      _review.suggestions(key, query);

  @override
  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  @override
  DuplicateSummary? get duplicateSummary => _load == ReviewLoad.ready
      ? DuplicateSummary.of([for (final u in _order) _items[u]!])
      : null;

  @override
  void chooseDuplicates(DuplicateGroup group) {
    final item = _currentItem;
    if (item == null || current?.canDecideDuplicates != true) return;
    _review.chooseDuplicates(item, group);
    _notify();
  }

  @override
  Future<void> useExisting() => _submit(
    (v) => v.useExistingTrackUuid != null,
    (item) => _review.resolveDuplicate(item, current!.useExistingTrackUuid!),
  );

  @override
  Future<void> dontImport() => _submit(
    (v) => v.dontImportTrackUuid != null,
    (item) => _review.resolveDuplicate(item, current!.dontImportTrackUuid!),
  );

  @override
  Future<void> backToReview() async {
    final uuid = _currentUuid;
    if (uuid == null || current?.canBackToReview != true || _busy) return;
    _busy = true;
    _notify();
    try {
      final outcome = await _review.backToReview(uuid);
      if (outcome == RetryOutcome.accepted) {
        try {
          await _reread(uuid);
        } catch (_) {
          // The next intent change reads the item again.
        }
      } else {
        _notice = retryOutcomeText(outcome);
      }
    } catch (_) {
      _notice = 'Something went wrong. Try again.';
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_preview.close());
    _intentsSub?.close();
    for (final s in _subs) {
      s.close();
    }
    super.dispose();
  }
}
