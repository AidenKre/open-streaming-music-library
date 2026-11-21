// Phase 8 spec §3, §6 paras 1-4: the Manage library page's input and
// presentation state (SC-26). Page-scoped: created when the page opens and
// disposed when it closes, which drops an unsubmitted selection. Rules live
// in the model (delete-jobs manager, availability, words); this controller
// forwards and translates.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/library_tools_pages.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

/// One selected track in the selected-items panel.
@immutable
class SelectedItemView {
  const SelectedItemView({
    required this.uuid,
    required this.title,
    required this.artist,
    required this.album,
    required this.inLocalLibrary,
  });

  final String uuid;

  /// Null when unknown (the track is no longer in the local library).
  final String? title;
  final String? artist;
  final String? album;

  /// False when sync removed the track after it was selected.
  final bool inLocalLibrary;
}

/// One target of a delete job, as the job view shows it.
@immutable
class JobTargetView {
  const JobTargetView({
    required this.uuid,
    required this.title,
    required this.artist,
    required this.outcome,
    required this.deleted,
  });

  final String uuid;

  /// Null when no title is known on this device.
  final String? title;
  final String? artist;

  /// Plain words (`deleteItemOutcomeText`), or the job's state before the
  /// server answered.
  final String outcome;

  /// Deleted or already deleted.
  final bool deleted;
}

@immutable
class DeleteJobView {
  const DeleteJobView({
    required this.operationUuid,
    required this.phase,
    required this.phaseText,
    required this.targets,
    this.refusal,
  });

  final String operationUuid;
  final DeleteJobPhase phase;
  final String phaseText;
  final List<JobTargetView> targets;

  /// Why the server refused the job (plain words), when it did.
  final String? refusal;
}

/// One receipt from `GET /tracks/deletions`.
@immutable
class ReceiptView {
  const ReceiptView({
    required this.operationUuid,
    required this.createdAt,
    required this.statusText,
    required this.itemCount,
  });

  final String operationUuid;

  /// Unix seconds.
  final int createdAt;
  final String statusText;
  final int itemCount;
}

enum ReceiptsLoad { idle, loading, loaded, failed, needsConnection }

abstract interface class ManageLibraryControls implements Listenable {
  ServerDeleteAvailability get availability;

  /// The page's selection (owned and disposed by this controller).
  TrackSelectionControls get selection;

  /// The preview and confirmation of [selection].
  DeletionReviewControls get review;

  /// The selection in order, with titles from the local library.
  List<SelectedItemView> get selectedItems;

  void removeSelected(String uuid);

  void clearSelection();

  /// The delete jobs this session knows (submitted here, recovered after a
  /// relaunch, or opened from a receipt), newest first.
  List<DeleteJobView> get jobs;

  ReceiptsLoad get receiptsLoad;

  /// What Deletion history says while [receiptsLoad] is
  /// [ReceiptsLoad.needsConnection]: why nothing can be read now.
  String get receiptsUnreachableText;

  /// A Retry beside [receiptsUnreachableText] can help (false while the
  /// session's server is blocked: only the banner's actions can clear that).
  bool get receiptsRetryHelps;

  /// Receipts loaded so far, in the server's keyset order.
  List<ReceiptView> get receipts;

  bool get hasMoreReceipts;

  /// Loads the first page of receipts again.
  Future<void> loadReceipts();

  Future<void> loadMoreReceipts();

  /// Repeats the last receipts request that failed or needed a connection.
  Future<void> retryReceipts();

  /// Shows a receipt's per-target results (the model follows the job).
  void openReceipt(String operationUuid);

  void dispose();
}

typedef ManageLibraryFactory = ManageLibraryControls Function();

/// Creates the page's controller. Override in tests.
final manageLibraryControllerFactoryProvider = Provider<ManageLibraryFactory>(
  (ref) =>
      () => ManageLibraryController(ref),
);

/// The page's input and presentation state; rules come from the model.
class ManageLibraryController extends ChangeNotifier
    implements ManageLibraryControls {
  ManageLibraryController(this._ref)
    : _manager = _ref.read(deleteJobsManagerProvider) {
    selection = _ref.read(trackSelectionControllerFactoryProvider)();
    review = _ref.read(deletionReviewControllerFactoryProvider)(selection);
    selection.addListener(_onSelection);
    review.addListener(_onReview);
    _manager.jobs.addListener(_onJobs);
    _subs.add(_ref.container.listen(libraryToolsFeatureProvider, (_, _) => _poke()));
    _subs.add(_ref.container.listen(offlineModeProvider, (prev, next) {
      if (next == true) _receiptsRefusal = null;
      _poke();
      if (next == false && _receiptsLoad == ReceiptsLoad.needsConnection) {
        unawaited(retryReceipts());
      }
    }));
    _subs.add(_ref.container.listen(
      libraryToolsServerBlockedProvider,
      (_, _) => _poke(),
    ));
    _onSelection();
    _onJobs();
  }

  final Ref _ref;
  final DeleteJobsManager _manager;
  final _subs = <ProviderSubscription<Object?>>[];
  bool _disposed = false;

  @override
  late final TrackSelectionControls selection;
  @override
  late final DeletionReviewControls review;

  List<SelectedItemView> _selectedItems = const [];
  List<DeleteJobView> _jobs = const [];
  int _selectionSeq = 0;
  int _jobsSeq = 0;
  final _remembered = <String, PreviewedTarget>{};
  final _appearance = <String>[];

  ReceiptsLoad _receiptsLoad = ReceiptsLoad.idle;
  List<ReceiptView> _receipts = const [];
  String? _nextAfter;

  /// Why the last receipts read was refused; cleared when a load starts.
  BindingRefusal? _receiptsRefusal;

  /// The last receipts request, for [retryReceipts].
  String? _lastAfter;
  bool _lastAppend = false;

  void _poke() {
    if (!_disposed) notifyListeners();
  }

  @override
  ServerDeleteAvailability get availability {
    return serverDeleteAvailabilityOf(
      _ref.read(libraryToolsFeatureProvider),
      offline: _ref.read(offlineModeProvider),
    );
  }

  @override
  List<SelectedItemView> get selectedItems => _selectedItems;

  @override
  List<DeleteJobView> get jobs => _jobs;

  @override
  ReceiptsLoad get receiptsLoad => _receiptsLoad;

  @override
  String get receiptsUnreachableText => deletionHistoryUnreachableText(
    libraryToolsUnreachable(
      blocked: _ref.read(libraryToolsServerBlockedProvider),
      refusal: _receiptsRefusal,
    ),
  );

  @override
  bool get receiptsRetryHelps =>
      libraryToolsRetryHelps(_ref.read(libraryToolsServerBlockedProvider));

  @override
  List<ReceiptView> get receipts => _receipts;

  @override
  bool get hasMoreReceipts => _nextAfter != null;

  Future<Map<String, TrackUI>> _hydrate(Iterable<String> uuids) async {
    final wanted = uuids.toSet().toList();
    if (wanted.isEmpty) return const {};
    final rows = await _ref.read(browseRepositoryProvider).getTracksByUuids(wanted);
    return {for (final t in rows) t.uuidId: t};
  }

  Future<void> _onSelection() async {
    final seq = ++_selectionSeq;
    final uuids = [for (final e in selection.selection.entries) e.uuid];
    final Map<String, TrackUI> local;
    try {
      local = await _hydrate(uuids);
    } catch (e) {
      debugPrint('selection hydration failed: ${e.runtimeType}: $e');
      return;
    }
    if (_disposed || seq != _selectionSeq) return;
    _selectedItems = [
      for (final u in uuids)
        SelectedItemView(
          uuid: u,
          title: local[u]?.title,
          artist: local[u]?.artist,
          album: local[u]?.album,
          inLocalLibrary: local.containsKey(u),
        ),
    ];
    notifyListeners();
  }

  void _onReview() {
    if (_disposed) return;
    final targets = review.preview?.targets;
    if (targets == null) return;
    for (final t in targets) {
      _remembered[t.uuid] = t;
    }
  }

  Future<void> _onJobs() async {
    final seq = ++_jobsSeq;
    final jobs = _manager.jobs.value;
    for (final op in jobs.keys) {
      if (!_appearance.contains(op)) _appearance.add(op);
    }
    // One total order, by one key: jobs still being sent or not yet
    // confirmed first; then newest first, by the server's date, else by when
    // this device submitted the job, else last; ties go to the job that
    // became known later.
    (int, int, int) key(DeleteJob j) => (
      j.phase == DeleteJobPhase.submitting ||
              j.phase == DeleteJobPhase.unconfirmed
          ? 0
          : 1,
      -(j.createdAt != null ? j.createdAt! * 1000 : j.submittedAtMs ?? 0),
      -_appearance.indexOf(j.operationUuid),
    );
    int byKey(DeleteJob a, DeleteJob b) {
      final (a1, a2, a3) = key(a);
      final (b1, b2, b3) = key(b);
      if (a1 != b1) return a1.compareTo(b1);
      if (a2 != b2) return a2.compareTo(b2);
      return a3.compareTo(b3);
    }
    final ordered = jobs.values.toList()..sort(byKey);
    final Map<String, TrackUI> local;
    try {
      local = await _hydrate([
        for (final j in ordered) ...[
          for (final t in j.targets) t.uuidId,
          for (final i in j.items) i.uuid,
        ],
      ]);
    } catch (e) {
      debugPrint('job hydration failed: ${e.runtimeType}: $e');
      return;
    }
    if (_disposed || seq != _jobsSeq) return;
    String? title(String u) => _remembered[u]?.title ?? local[u]?.title;
    String? artist(String u) => _remembered[u]?.artist ?? local[u]?.artist;
    _jobs = [
      for (final j in ordered)
        _viewOf(j, title, artist),
    ];
    notifyListeners();
  }

  DeleteJobView _viewOf(
    DeleteJob job,
    String? Function(String) title,
    String? Function(String) artist,
  ) {
    final rows = job.items.isNotEmpty
        ? [
            for (final i in job.items)
              (uuid: i.uuid, outcome: deleteItemOutcomeText(i), deleted: i.isGone),
          ]
        : [
            for (final t in job.targets)
              (
                uuid: t.uuidId,
                outcome: jobPhaseText(job.phase),
                deleted: false,
              ),
          ];
    return DeleteJobView(
      operationUuid: job.operationUuid,
      phase: job.phase,
      phaseText: jobPhaseText(job.phase),
      refusal: job.phase == DeleteJobPhase.rejected
          ? deletionErrorText(job.rejectionCode)
          : null,
      targets: [
        for (final r in rows)
          JobTargetView(
            uuid: r.uuid,
            title: title(r.uuid),
            artist: artist(r.uuid),
            outcome: r.outcome,
            deleted: r.deleted,
          ),
      ],
    );
  }

  @override
  void removeSelected(String uuid) {
    if (!_disposed) selection.deselect(uuid);
  }

  @override
  void clearSelection() {
    if (!_disposed) selection.clear();
  }

  @override
  Future<void> loadReceipts() => _loadReceipts(after: null, append: false);

  @override
  Future<void> loadMoreReceipts() async {
    final after = _nextAfter;
    if (after == null || _receiptsLoad == ReceiptsLoad.loading) return;
    await _loadReceipts(after: after, append: true);
  }

  Future<void> _loadReceipts({
    required String? after,
    required bool append,
  }) async {
    if (_disposed || _receiptsLoad == ReceiptsLoad.loading) return;
    _lastAfter = after;
    _lastAppend = append;
    _receiptsRefusal = null;
    // Offline nothing can be asked: say so at once (as the preview does).
    if (_ref.read(offlineModeProvider)) {
      _receiptsLoad = ReceiptsLoad.needsConnection;
      notifyListeners();
      return;
    }
    _receiptsLoad = ReceiptsLoad.loading;
    notifyListeners();
    try {
      final page = await _ref
          .read(libraryToolsApiProvider)
          .listJobs(after: after, waitForBinding: false);
      if (_disposed) return;
      final fresh = [
        for (final j in page.jobs)
          ReceiptView(
            operationUuid: j.operationUuid,
            createdAt: j.createdAt,
            statusText: receiptStatusText(j.status),
            itemCount: j.itemCount,
          ),
      ];
      _receipts = append ? [..._receipts, ...fresh] : fresh;
      _nextAfter = page.nextAfter;
      _receiptsLoad = ReceiptsLoad.loaded;
    } on LibraryToolsNotConnected catch (e) {
      if (_disposed) return;
      _receiptsRefusal = e.reason;
      _receiptsLoad = ReceiptsLoad.needsConnection;
      _reload.arm();
    } catch (_) {
      if (_disposed) return;
      _receiptsLoad = ReceiptsLoad.failed;
    }
    notifyListeners();
  }

  /// A read that failed fast as not connected repeats by itself once the
  /// binding verifies.
  late final _reload = ReloadWhenVerified(
    whenVerified: () => _ref.read(libraryToolsApiProvider).whenVerified(),
    onVerified: _onVerified,
  );

  void _onVerified() {
    if (_disposed || _receiptsLoad != ReceiptsLoad.needsConnection) return;
    unawaited(retryReceipts());
  }

  @override
  Future<void> retryReceipts() =>
      _loadReceipts(after: _lastAfter, append: _lastAppend);

  @override
  void openReceipt(String operationUuid) {
    if (!_disposed) _manager.follow(operationUuid);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    selection.removeListener(_onSelection);
    review.removeListener(_onReview);
    _manager.jobs.removeListener(_onJobs);
    for (final s in _subs) {
      s.close();
    }
    review.dispose();
    selection.dispose();
    super.dispose();
  }
}
