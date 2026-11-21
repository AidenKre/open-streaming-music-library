// Phase 8 spec §6 "Possible duplicates": the page's input and presentation
// state (SC-26). Page-scoped: created when the page opens, disposed when it
// closes. Every rule (badge, differing fields, header words, order,
// availability of server deletion, the delete review, when "Delete this
// copy" is blocked and what a pair's deletion status says) lives in the
// model; this controller forwards and translates.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/duplicates/duplicates_delete_rules.dart';
import 'package:frontend/services/duplicates/duplicates_header.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/services/deletion/sync_touch.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/library_tools_pages.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';

/// The Open / Dismissed chips.
enum DuplicatesFilter { open, dismissed }

enum DuplicatesLoad {
  idle,
  loading,
  loaded,
  failed,

  /// Offline: nothing is asked of the server.
  needsConnection,
}

/// One copy of a pair as a row shows it.
@immutable
class DuplicateCopyView {
  const DuplicateCopyView({
    required this.track,
    required this.fields,
    required this.identityLines,
  });

  /// The server's snapshot of this copy, as the list loaded it.
  final DuplicatePairTrackDto track;

  String get uuid => track.uuidId;

  /// Every compared field's words, `Unknown` included.
  final Map<DuplicateField, String> fields;

  /// What names this copy in a deletion confirmation (known values only).
  final List<String> identityLines;
}

/// One pair row.
@immutable
class DuplicatePairView {
  const DuplicatePairView({
    required this.pair,
    required this.badge,
    required this.isExact,
    required this.a,
    required this.b,
    required this.differing,
  });

  /// The server's pair, as the list loaded it.
  final DuplicatePairDto pair;
  final String badge;
  final bool isExact;
  final DuplicateCopyView a;
  final DuplicateCopyView b;

  /// Fields whose known values differ (unknown never differs).
  final Set<DuplicateField> differing;

  String get key => pairKey(pair.uuidA, pair.uuidB);
}

abstract interface class DuplicatesControls implements Listenable {
  DuplicatesFilter get filter;

  /// A chip change starts a new listing; an earlier cursor is never reused.
  void setFilter(DuplicatesFilter filter);

  DuplicatesLoad get summaryLoad;

  /// The header for the last summary; null until one arrived.
  DuplicatesHeader? get header;

  DuplicatesLoad get listLoad;

  /// The listed pairs, in the server's order.
  List<DuplicatePairView> get pairs;

  bool get hasMore;

  Future<void> loadMore();

  /// Loads the summary and the first page of the current chip again.
  Future<void> refresh();

  /// What the page says while [summaryLoad] or [listLoad] is
  /// [DuplicatesLoad.needsConnection]: why nothing can be read now.
  String get unreachableText;

  /// A Retry beside [unreachableText] can help (false while the session's
  /// server is blocked: only the banner's actions can clear that).
  bool get connectionRetryHelps;

  /// Plain words for the last failed action; null when there is none.
  String? get message;

  void clearMessage();

  /// "Not duplicates" (Open chip) or "Restore" (Dismissed chip): the row
  /// leaves the list at once; it comes back on [undo] or on a failure.
  /// False when [pair] is no longer listed as shown (nothing was done).
  bool setAside(DuplicatePairView pair);

  /// Undoes [setAside] of [pair].
  void undo(DuplicatePairView pair);

  /// Play is offered (online only: the preview player streams).
  bool get canPlay;

  /// The copy the preview player is on, and its status.
  String? get previewingUuid;
  PreviewStatus get previewStatus;

  /// What the user is told about the preview, or null.
  String? get previewMessage;

  /// Plays [uuid] through the preview player, or pauses it when it is the
  /// one playing.
  Future<void> togglePlay(String uuid);

  /// The page is being left: the preview stops. Called from the page's pop
  /// event, never from a dispose.
  void leave();

  /// "Delete this copy" is offered (the server's switch is on, live, and
  /// the app is online).
  bool get canDeleteCopy;

  /// Starts the single-track review of copy [uuid] of [pair] as the row
  /// showed it; null when it can't be offered now.
  DeletionReviewControls? startDeleteCopy(DuplicatePairView pair, String uuid);

  /// The review sheet closed.
  void endDeleteCopy(DeletionReviewControls review);

  /// Plain words for the deletion of a copy of [pair] started here: the
  /// job's state, then the copy's outcome; null when there is none.
  String? deleteStatus(DuplicatePairView pair);

  /// A copy of [pair] is being deleted, or was: neither copy may be
  /// deleted again from here (the other may be the last copy).
  bool deleteBlocked(DuplicatePairView pair);

  void dispose();
}

typedef DuplicatesFactory = DuplicatesControls Function();

/// Creates the page's controller. Override in tests.
final duplicatesControllerFactoryProvider = Provider<DuplicatesFactory>(
  (ref) =>
      () => DuplicatesController(ref),
);

class DuplicatesController extends ChangeNotifier
    implements DuplicatesControls {
  DuplicatesController(this._ref) {
    _syncSub = _ref.container.listen(trackSyncProvider, (prev, next) {
      if (prev?.value?.isSyncing == true && next.value?.isSyncing == false) {
        _onSyncFinished(next.value!);
      }
    });
    _offlineSub = _ref.container.listen(offlineModeProvider, (prev, next) {
      if (next) {
        _refusal = null;
        _notify();
      } else {
        refresh();
      }
    });
    _previewSub = _ref.container.listen(
      previewPlayerProvider,
      (_, _) => _notify(),
    );
    _featureSub = _ref.container.listen(
      libraryToolsFeatureProvider,
      (_, _) => _notify(),
    );
    _blockedSub = _ref.container.listen(
      libraryToolsServerBlockedProvider,
      (_, _) => _notify(),
    );
    // Jobs started elsewhere count too.
    _watchJobs();
    refresh();
  }

  final Ref _ref;
  late final ProviderSubscription<PreviewState> _previewSub;
  late final ProviderSubscription<Object?> _featureSub;
  late final ProviderSubscription<ServerBlockedReason> _blockedSub;
  late final ProviderSubscription<AsyncValue<TrackSyncState>> _syncSub;
  late final ProviderSubscription<bool> _offlineSub;
  bool _disposed = false;

  DuplicatesFilter _filter = DuplicatesFilter.open;
  DuplicatesLoad _summaryLoad = DuplicatesLoad.idle;
  DuplicatesHeader? _header;
  DuplicatesLoad _listLoad = DuplicatesLoad.idle;
  List<DuplicatePairView> _pairs = const [];
  String? _cursor;
  bool _pageInFlight = false;
  int _listSeq = 0;
  int _summarySeq = 0;

  void _notify() {
    if (_disposed) return;
    _revalidateDelete();
    notifyListeners();
  }

  @override
  DuplicatesFilter get filter => _filter;

  @override
  void setFilter(DuplicatesFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    _pairs = const [];
    _cursor = null;
    _startListing();
  }

  @override
  DuplicatesLoad get summaryLoad => _summaryLoad;

  @override
  DuplicatesHeader? get header => _header;

  @override
  DuplicatesLoad get listLoad => _listLoad;

  @override
  List<DuplicatePairView> get pairs => _pairs;

  @override
  bool get hasMore => _cursor != null;

  @override
  Future<void> refresh() async {
    if (_disposed) return;
    _refusal = null;
    if (_ref.read(offlineModeProvider)) {
      _summarySeq++;
      _listSeq++;
      _pageInFlight = false;
      _summaryLoad = DuplicatesLoad.needsConnection;
      _listLoad = DuplicatesLoad.needsConnection;
      _notify();
      return;
    }
    await Future.wait([_loadSummary(), _startListing(), _loadUnfinished()]);
  }

  /// The server's unfinished deletions were read during this page's life.
  bool _unfinishedKnown = false;

  Future<void> _loadUnfinished() async {
    final manager = _manager;
    if (manager == null) return;
    if (await manager.loadUnfinished() && !_disposed) {
      _unfinishedKnown = true;
      _notify();
    }
  }

  /// Reads the scan summary. A quiet read while a header is shown keeps that
  /// header and its load state when it fails (a refusal as not connected also
  /// marks the summary as owed, read again once the binding verifies); any
  /// other read that fails clears the header and shows failed / needsConnection.
  Future<void> _loadSummary({bool quiet = false}) async {
    final seq = ++_summarySeq;
    // Shown: loaded, not behind the spinner of a reload in flight.
    final keepPlace =
        quiet && _header != null && _summaryLoad == DuplicatesLoad.loaded;
    if (!keepPlace) {
      _summaryLoad = DuplicatesLoad.loading;
      _notify();
    }
    try {
      final dto = await _ref.read(libraryToolsApiProvider).duplicateSummary(waitForBinding: false);
      if (_disposed || seq != _summarySeq) return;
      _header = duplicatesHeader(dto);
      _summaryLoad = DuplicatesLoad.loaded;
      _summaryOwed = false;
    } on LibraryToolsNotConnected catch (e) {
      if (_disposed || seq != _summarySeq) return;
      _refusal = e.reason;
      if (keepPlace) {
        _summaryOwed = true;
      } else {
        _header = null;
        _summaryLoad = DuplicatesLoad.needsConnection;
      }
      _reload.arm();
    } catch (_) {
      if (_disposed || seq != _summarySeq) return;
      if (keepPlace) return;
      _header = null;
      _summaryLoad = DuplicatesLoad.failed;
    }
    _notify();
  }

  /// A quiet summary read that was refused as not connected, while a header
  /// was shown and kept.
  bool _summaryOwed = false;

  /// A load that failed fast as not connected reloads by itself once the
  /// binding verifies.
  late final _reload = ReloadWhenVerified(
    whenVerified: () => _ref.read(libraryToolsApiProvider).whenVerified(),
    onVerified: _onVerified,
  );

  /// Only what needs it is read again: the summary (quietly if a header is
  /// shown) and, only when the listing itself needs a connection, the
  /// listing. Offline: nothing (coming back online reloads).
  void _onVerified() {
    if (_disposed || _ref.read(offlineModeProvider)) return;
    if (_summaryLoad == DuplicatesLoad.needsConnection || _summaryOwed) {
      unawaited(_loadSummary(quiet: _header != null));
    }
    if (_listLoad == DuplicatesLoad.needsConnection) {
      unawaited(_startListing());
    }
    if (!_unfinishedKnown) unawaited(_loadUnfinished());
  }

  Future<void> _startListing() {
    if (_ref.read(offlineModeProvider)) {
      _refusal = null;
      _listSeq++;
      _pageInFlight = false;
      _listLoad = DuplicatesLoad.needsConnection;
      _notify();
      return Future.value();
    }
    _cursor = null;
    _pairs = const [];
    return _loadPage(++_listSeq, null, first: true);
  }

  @override
  Future<void> loadMore() async {
    final cursor = _cursor;
    if (_disposed || cursor == null || _pageInFlight) return;
    await _loadPage(_listSeq, cursor, first: false);
  }

  Future<void> _loadPage(int seq, String? after, {required bool first}) async {
    final filter = _filter;
    // Undos not yet confirmed: the server may still list their pairs as
    // set aside, so a page that lands for them is stale about those pairs.
    final unconfirmed = [
      for (final a in _asides.values)
        if (a.undone && !a.failed && !a.undoConfirmed && a.filter == filter) a,
    ];
    _pageInFlight = true;
    _listLoad = DuplicatesLoad.loading;
    _notify();
    try {
      final page = await _ref
          .read(libraryToolsApiProvider)
          .listDuplicates(
            status: filter == DuplicatesFilter.open ? 'open' : 'dismissed',
            after: after,
            waitForBinding: false,
          );
      if (_disposed || seq != _listSeq || filter != _filter) return;
      // Their rows may have been put back already; re-place them in order.
      final stale = {for (final a in unconfirmed) a.row.key};
      _pairs = [
        for (final p in _pairs)
          if (!stale.contains(p.key)) p,
        for (final p in page.pairs)
          if (!_asideActive(p.uuidA, p.uuidB, filter) &&
              !_hasDeletedMember(p) &&
              !_pairs.any((q) => q.key == pairKey(p.uuidA, p.uuidB)))
            _view(p),
      ];
      _cursor = page.nextAfter;
      for (final a in unconfirmed) {
        if (a.undone && !a.failed) _reinsert(a);
      }
      _listLoad = DuplicatesLoad.loaded;
    } catch (e) {
      if (_disposed || seq != _listSeq || filter != _filter) return;
      if (first) {
        _pairs = const [];
        _cursor = null;
      }
      _listLoad = e is LibraryToolsNotConnected
          ? DuplicatesLoad.needsConnection
          : DuplicatesLoad.failed;
      if (e is LibraryToolsNotConnected) {
        _refusal = e.reason;
        _reload.arm();
      }
    }
    _pageInFlight = false;
    _notify();
  }

  DuplicatePairView _view(DuplicatePairDto p) => DuplicatePairView(
    pair: p,
    badge: duplicateBadgeText(p),
    isExact: isExactPair(p),
    a: _copy(p.trackA),
    b: _copy(p.trackB),
    differing: differingFields(p.trackA, p.trackB),
  );

  DuplicateCopyView _copy(DuplicatePairTrackDto t) => DuplicateCopyView(
    track: t,
    fields: {
      for (final f in DuplicateField.values) f: duplicateFieldText(t, f),
    },
    identityLines: copyIdentityLines(t),
  );

  String? _message;

  /// Why the latest summary or list read was refused (the latest refusal
  /// wins); cleared when a load starts or takes the offline branch.
  BindingRefusal? _refusal;

  @override
  String get unreachableText => duplicatesUnreachableText(
    libraryToolsUnreachable(
      blocked: _ref.read(libraryToolsServerBlockedProvider),
      refusal: _refusal,
    ),
  );

  @override
  bool get connectionRetryHelps =>
      libraryToolsRetryHelps(_ref.read(libraryToolsServerBlockedProvider));

  @override
  String? get message => _message;

  @override
  void clearMessage() {
    if (_message == null) return;
    _message = null;
    _notify();
  }

  // Set-aside bookkeeping, per pair key.
  final _asides = <String, _Aside>{};
  final _chains = <String, Future<void>>{};

  static const _gone = 'This pair is no longer in your library.';

  bool _listed(DuplicatePairView row) => _pairs.any(
    (p) => p.key == row.key && identical(p.pair, row.pair),
  );

  @override
  bool setAside(DuplicatePairView pair) {
    if (_disposed || !_listed(pair)) return false;
    final aside = _Aside(pair, _filter);
    _asides[pair.key] = aside;
    _pairs = [for (final p in _pairs) if (p.key != pair.key) p];
    _notify();
    _chain(pair.key, () => _runFirst(aside));
    return true;
  }

  @override
  void undo(DuplicatePairView pair) {
    final aside = _asides[pair.key];
    if (_disposed ||
        aside == null ||
        aside.failed ||
        aside.undone ||
        !identical(aside.row.pair, pair.pair)) {
      return;
    }
    aside.undone = true;
    _reinsert(aside);
    _notify();
    _chain(pair.key, () => _runUndo(aside));
  }

  void _chain(String key, Future<void> Function() step) {
    final prev = _chains[key] ?? Future<void>.value();
    _chains[key] = prev.then((_) => step());
  }

  Future<void> _call(_Aside a, {required bool dismiss}) {
    final api = _ref.read(libraryToolsApiProvider);
    final p = a.row.pair;
    return dismiss
        ? api.dismissPair(p.uuidA, p.uuidB)
        : api.restorePair(p.uuidA, p.uuidB);
  }

  Future<void> _runFirst(_Aside a) async {
    try {
      await _call(a, dismiss: a.dismissFirst);
    } catch (e) {
      if (_disposed) return;
      a.failed = true;
      if (_isGone(e)) {
        _removeIfCurrent(a);
        _message = _gone;
      } else {
        if (!a.undone) _reinsert(a);
        _message = a.dismissFirst
            ? "Couldn't mark these as not duplicates. Nothing changed."
            : "Couldn't restore this pair. Nothing changed.";
      }
      _notify();
      return;
    }
    if (_disposed) return;
    await _loadSummary();
  }

  Future<void> _runUndo(_Aside a) async {
    if (a.failed) return;
    try {
      await _call(a, dismiss: !a.dismissFirst);
    } catch (e) {
      if (_disposed) return;
      a.failed = true;
      _removeIfCurrent(a);
      _message = _isGone(e)
          ? _gone
          : a.dismissFirst
          ? "Couldn't undo. The pair stays under Dismissed."
          : "Couldn't undo. The pair stays under Open.";
      _notify();
      return;
    }
    if (_disposed) return;
    // Confirmed: the pair belongs in the list whatever a load that started
    // before this answer said.
    a.undoConfirmed = true;
    if (identical(_asides[a.row.key], a)) {
      _reinsert(a);
      _notify();
    }
    await _loadSummary();
  }

  bool _isGone(Object e) => e is ApiException && e.errorCode == 'pair_not_found';

  /// A set-aside of [uuidA]|[uuidB] on [filter] that is neither undone nor
  /// failed: the server is (or will be) holding the pair on the other chip.
  bool _asideActive(String uuidA, String uuidB, DuplicatesFilter filter) {
    final a = _asides[pairKey(uuidA, uuidB)];
    return a != null && !a.undone && !a.failed && a.filter == filter;
  }

  void _removeIfCurrent(_Aside a) {
    if (_filter == a.filter) _remove(a);
  }

  void _remove(_Aside a) {
    _pairs = [for (final p in _pairs) if (p.key != a.row.key) p];
  }

  void _reinsert(_Aside a) {
    if (_filter != a.filter ||
        _hasDeletedMember(a.row.pair) ||
        _pairs.any((p) => p.key == a.row.key)) {
      return;
    }
    var i = _pairs.indexWhere(
      (p) => compareDuplicatePairs(a.row.pair, p.pair) < 0,
    );
    if (i < 0) {
      // Past the loaded range with more pages to come: it arrives with its
      // own page.
      if (_cursor != null) return;
      i = _pairs.length;
    }
    _pairs = [..._pairs.sublist(0, i), a.row, ..._pairs.sublist(i)];
  }

  @override
  // Offline, or the server check failed (sign-off OPEN-M-11: as playback).
  bool get canPlay => !_ref.read(streamsUnavailableProvider)();

  PreviewState get _preview => _ref.read(previewPlayerProvider);

  @override
  String? get previewingUuid => switch (_preview.source) {
    LibraryTrackPreview(:final trackUuid) => trackUuid,
    _ => null,
  };

  @override
  PreviewStatus get previewStatus =>
      previewingUuid == null ? PreviewStatus.idle : _preview.status;

  @override
  String? get previewMessage => previewStatusMessage(previewStatus);

  @override
  Future<void> togglePlay(String uuid) async {
    if (_disposed || !canPlay) return;
    final controls = _ref.read(previewControlsProvider);
    if (previewingUuid == uuid && previewStatus == PreviewStatus.paused) {
      await controls.resume();
    } else if (previewingUuid == uuid && previewIsActive(previewStatus)) {
      await controls.pause();
    } else {
      await controls.playLibraryTrack(uuid);
    }
  }

  @override
  void leave() {
    if (_disposed) return;
    unawaited(_ref.read(previewControlsProvider).close());
  }

  @override
  bool get canDeleteCopy {
    final feature = _ref.read(libraryToolsFeatureProvider);
    return serverDeleteAvailability(
          loading: !feature.hasValue && !feature.hasError,
          failed: feature.hasError && !feature.hasValue,
          advertised: feature.hasValue ? feature.value : null,
          offline: _ref.read(offlineModeProvider),
        ) ==
        ServerDeleteAvailability.enabled;
  }

  _ActiveDelete? _delete;

  @override
  DeletionReviewControls? startDeleteCopy(
    DuplicatePairView pair,
    String uuid,
  ) {
    if (_disposed || !canDeleteCopy || !_listed(pair)) return null;
    if (_delete != null || deleteBlocked(pair)) return null;
    final DuplicatePairTrackDto track;
    if (uuid == pair.pair.uuidA) {
      track = pair.pair.trackA;
    } else if (uuid == pair.pair.uuidB) {
      track = pair.pair.trackB;
    } else {
      return null;
    }
    final sel = _ref.read(trackSelectionControllerFactoryProvider)();
    sel.select(track.uuidId, baseRevision: track.revision);
    final review = _ref.read(deletionReviewControllerFactoryProvider)(sel);
    unawaited(review.requestPreview());
    final active = _ActiveDelete(pair.pair, sel, review, track.uuidId, track.revision);
    active.listener = () => _selectionChanged(active);
    sel.addListener(active.listener);
    _delete = active;
    return review;
  }

  @override
  void endDeleteCopy(DeletionReviewControls review) {
    final d = _delete;
    if (d == null || d.review != review) return;
    final op = review.submittedOperation;
    if (op != null) {
      _ops.add((
        operation: op,
        pairKey: pairKey(d.pair.uuidA, d.pair.uuidB),
        uuid: d.uuid,
      ));
      _watchJobs();
    }
    _endActive();
  }

  static const _changed =
      'This pair changed while you were reviewing it. Nothing was deleted.';

  /// The review's Refresh adopted the server's revision for the tapped copy:
  /// what the row showed is no longer what would be confirmed.
  void _selectionChanged(_ActiveDelete d) {
    if (_disposed || !identical(_delete, d)) return;
    final entries = d.selection.selection.entries;
    if (entries.length == 1 &&
        entries.single.uuid == d.uuid &&
        entries.single.baseRevision != d.revision) {
      _dropActiveDelete();
      notifyListeners();
    }
  }

  /// Tracks deleted by finished syncs during this controller's life: a pair
  /// with such a member is never listed, whatever a late answer says.
  final _deletedUuids = <String>{};

  bool _hasDeletedMember(DuplicatePairDto p) =>
      _deletedUuids.contains(p.uuidA) || _deletedUuids.contains(p.uuidB);

  /// A finished sync changes the list only by the tracks it deleted (their
  /// pairs go with them on the server): those pairs leave the list here, the
  /// open review is dropped only if its pair was one of them, and the scan
  /// summary is read again, quietly: a failed read keeps the header shown.
  /// The pages and cursor stay as they are.
  void _onSyncFinished(TrackSyncState finished) {
    if (_disposed) return;
    if (finished.deletedTrackUuids.isNotEmpty) {
      _deletedUuids.addAll(finished.deletedTrackUuids);
      bool touched(DuplicatePairDto p) =>
          syncTouched(finished, [p.uuidA, p.uuidB]);
      final d = _delete;
      if (d != null && touched(d.pair)) _dropActiveDelete();
      _pairs = [
        for (final p in _pairs)
          if (!touched(p.pair)) p,
      ];
      _notify();
    }
    // Offline the page already says it needs a connection: ask nothing.
    if (_ref.read(offlineModeProvider)) return;
    unawaited(_loadSummary(quiet: true));
  }

  /// Clears an active review's selection that has not been submitted, and
  /// says the pair changed when it did.
  void _dropActiveDelete({bool changed = true}) {
    final d = _delete;
    if (d == null ||
        d.review.submittedOperation != null ||
        d.review.stage == ReviewStage.submitting ||
        d.selection.selection.isEmpty) {
      return;
    }
    d.selection.clear();
    if (changed) _message = _changed;
  }

  final _ops = <SubmittedCopyDeletion>[];
  ValueListenable<Map<String, DeleteJob>>? _watched;

  void _watchJobs() {
    if (_watched != null) return;
    final jobs = _manager?.jobs;
    if (jobs == null) return;
    jobs.addListener(_jobsChanged);
    _watched = jobs;
  }

  void _jobsChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Session-wide jobs (this page's, Manage library's, earlier visits').
  Map<String, DeleteJob> get _jobs => _manager?.jobs.value ?? const {};

  /// The manager, or null where the session has none (it can't be built).
  DeleteJobsManager? get _manager {
    try {
      return _ref.read(deleteJobsManagerProvider);
    } catch (_) {
      return null;
    }
  }

  void _endActive() {
    final d = _delete;
    if (d == null) return;
    _delete = null;
    d.selection.removeListener(d.listener);
    d.review.dispose();
    d.selection.dispose();
  }

  /// A review that is no longer the pair as tapped loses its selection, so
  /// its preview drops and it can't be confirmed.
  void _revalidateDelete() {
    final d = _delete;
    if (d == null) return;
    // The list is being reloaded: judge the new answer, not the gap.
    if (_listLoad == DuplicatesLoad.loading && _pairs.isEmpty) return;
    // Offline or a capability change: the review goes, but the pair did not
    // change, so it is not said to have.
    if (!canDeleteCopy) return _dropActiveDelete(changed: false);
    if (_pairs.any((p) => sameDuplicatePairSnapshot(p.pair, d.pair))) return;
    _dropActiveDelete();
  }

  @override
  String? deleteStatus(DuplicatePairView pair) =>
      duplicateDeleteStatus(pair.pair, _jobs.values);

  @override
  bool deleteBlocked(DuplicatePairView pair) =>
      duplicateDeleteBlocked(
        pair.pair,
        jobs: _jobs,
        submitted: _ops,
        // Without a manager nothing can be deleted from here.
        unfinishedKnown: _unfinishedKnown || _manager == null,
      );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _syncSub.close();
    _offlineSub.close();
    _previewSub.close();
    _featureSub.close();
    _blockedSub.close();
    _endActive();
    _watched?.removeListener(_jobsChanged);
    _watched = null;
    super.dispose();
  }
}

class _Aside {
  _Aside(this.row, this.filter);
  final DuplicatePairView row;
  final DuplicatesFilter filter;
  bool failed = false;
  bool undone = false;

  /// The undo request succeeded on the server.
  bool undoConfirmed = false;

  /// The first request: dismiss on the Open chip, restore on Dismissed.
  bool get dismissFirst => filter == DuplicatesFilter.open;
}

class _ActiveDelete {
  _ActiveDelete(
    this.pair,
    this.selection,
    this.review,
    this.uuid,
    this.revision,
  );
  final DuplicatePairDto pair;
  final String uuid;
  final int? revision;
  late VoidCallback listener;
  final TrackSelectionControls selection;
  final DeletionReviewControls review;
}
