// Phase 8 spec §4 para 3, §6: the review of one selection before server
// deletion (preview, refresh, remove, confirm). SC-26 controller: it holds
// presentation state and forwards to the delete-jobs model, which owns every
// rule (verdicts, confirmability, the one-operation-per-preview freeze, the
// awaiting-answer refusal). Reused by Possible duplicates (8B.3) with a
// one-track selection.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/deletion/sync_touch.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

enum ReviewStage {
  /// No preview for the current selection.
  idle,

  /// Asking the server.
  previewing,

  /// [DeletionReviewControls.preview] is the server's answer for exactly the
  /// current selection.
  ready,

  /// The preview could not be made; [DeletionReviewControls.message] says
  /// why.
  failed,

  /// A confirmed deletion is being frozen and handed to the model.
  submitting,

  /// Handed over; [DeletionReviewControls.submittedOperation] names it.
  submitted,
}

abstract interface class DeletionReviewControls implements Listenable {
  ReviewStage get stage;

  /// The server's preview of exactly the current selection; null otherwise.
  DeletionPreview? get preview;

  /// Plain words for the last failure or refusal; null when there is none.
  String? get message;

  /// Why the current preview can't be confirmed (plain words); null when it
  /// can, or when there is no preview.
  String? get blockedReason;

  /// The confirm action may be offered now.
  bool get canConfirm;

  /// The operation of the last confirmed deletion.
  String? get submittedOperation;

  /// The selection emptied without a deletion handed over: there is
  /// nothing left to review, and the review sheet closes.
  bool get nothingToReview;

  /// Asks the server about the current selection (1-100 tracks).
  Future<void> requestPreview();

  /// The user's explicit Refresh of [uuid]: the selection takes the
  /// preview's server revision for it, and the selection is previewed again.
  Future<void> refreshTarget(String uuid);

  /// Removes [uuid] from the selection and previews the rest again.
  Future<void> removeTarget(String uuid);

  /// Submits exactly [shown], the preview the confirmation displayed, with
  /// [confirmedCount]. Sends nothing unless [shown] is still the preview of
  /// the current selection. True when the deletion was handed to the model.
  Future<bool> confirm(DeletionPreview shown, {required int confirmedCount});

  void dispose();
}

typedef DeletionReviewFactory =
    DeletionReviewControls Function(TrackSelectionControls selection);

/// Creates a review over a page's selection. Override in tests.
final deletionReviewControllerFactoryProvider = Provider<DeletionReviewFactory>(
  (ref) =>
      (selection) => DeletionReviewController(ref, selection),
);

/// Presentation state of one review; every rule is the model's (SC-26).
class DeletionReviewController extends ChangeNotifier
    implements DeletionReviewControls {
  DeletionReviewController(Ref ref, TrackSelectionControls selection)
    : _manager = ref.read(deleteJobsManagerProvider),
      _selection = selection {
    _selection.addListener(_onSelectionChanged);
    // `canConfirm` / `blockedReason` read the awaiting-answer state, which
    // changes when a job's answer arrives.
    _manager.jobs.addListener(_onJobsChanged);
    _syncSub = ref.container.listen(trackSyncProvider, (prev, next) {
      if (prev?.value?.isSyncing == true && next.value?.isSyncing == false) {
        _onSyncFinished(next.value!);
      }
    });
  }

  final DeleteJobsManager _manager;
  final TrackSelectionControls _selection;
  late final ProviderSubscription<AsyncValue<TrackSyncState>> _syncSub;
  ReviewStage _stage = ReviewStage.idle;
  DeletionPreview? _preview;
  String? _message;
  String? _submittedOperation;
  int _seq = 0;
  bool _submitting = false;
  bool _disposed = false;

  @override
  ReviewStage get stage => _stage;

  @override
  DeletionPreview? get preview => _preview;

  @override
  String? get message => _message;

  @override
  String? get submittedOperation => _submittedOperation;

  @override
  bool get nothingToReview =>
      _selection.count == 0 &&
      _stage != ReviewStage.submitting &&
      _stage != ReviewStage.submitted;

  List<DeletionCandidate> get _candidates => [
    for (final e in _selection.selection.entries)
      DeletionCandidate(e.uuid, e.baseRevision),
  ];

  bool get _awaiting =>
      _preview != null &&
      _manager.awaitingAnswer([for (final t in _preview!.targets) t.uuid]);

  @override
  String? get blockedReason {
    final p = _preview;
    if (p == null || _stage != ReviewStage.ready) return null;
    if (!p.confirmable) {
      return notConfirmableText(
        needsRefresh: p.targets.any(
          (t) => t.verdict == PreviewVerdict.revisionUnknown,
        ),
      );
    }
    return _awaiting ? awaitingAnswerText() : null;
  }

  @override
  bool get canConfirm {
    final p = _preview;
    return p != null &&
        _stage == ReviewStage.ready &&
        p.confirmable &&
        p.isFor(_candidates) &&
        !_awaiting;
  }

  void _set(ReviewStage stage, {String? message, bool keepMessage = false}) {
    _stage = stage;
    if (!keepMessage) _message = message;
    if (!_disposed) notifyListeners();
  }

  void _onSelectionChanged() {
    if (_disposed) return;
    final p = _preview;
    if (p != null && !p.isFor(_candidates)) {
      _preview = null;
      if (_stage == ReviewStage.ready || _stage == ReviewStage.failed) {
        _set(ReviewStage.idle);
      } else {
        notifyListeners();
      }
    } else if (p == null && _stage == ReviewStage.failed) {
      _set(ReviewStage.idle);
    }
  }

  void _onJobsChanged() {
    if (!_disposed) notifyListeners();
  }

  void _onSyncFinished(TrackSyncState finished) {
    if (_disposed) return;
    // A sync that did not touch the selected tracks changes nothing here.
    if (!syncTouched(finished, [
      for (final e in _selection.selection.entries) e.uuid,
    ])) {
      return;
    }
    _seq++;
    _preview = null;
    if (_stage == ReviewStage.submitting) return;
    _set(ReviewStage.idle, message: libraryChangedText());
  }

  @override
  Future<void> requestPreview() async {
    if (_disposed || _submitting) return;
    final candidates = _candidates;
    final seq = ++_seq;
    _preview = null;
    if (candidates.isEmpty) {
      _set(ReviewStage.idle);
      return;
    }
    if (candidates.length > DeleteJobsManager.maxTargetsPerJob) {
      _set(
        ReviewStage.idle,
        message: tooManyTracksText(DeleteJobsManager.maxTargetsPerJob),
      );
      return;
    }
    _set(ReviewStage.previewing);
    try {
      final answer = await _manager.preview(candidates);
      if (_disposed || seq != _seq) return;
      if (answer.isFor(_candidates)) {
        _preview = answer;
        _set(ReviewStage.ready);
      } else {
        _set(ReviewStage.idle);
      }
    } on DeleteJobsUnavailable catch (e) {
      if (_disposed || seq != _seq) return;
      _set(ReviewStage.failed, message: unavailableText(e.reason));
    } on ApiException catch (e) {
      if (_disposed || seq != _seq) return;
      _set(
        ReviewStage.failed,
        message: deletionPreviewErrorText(e.statusCode, e.errorCode),
      );
    } on FormatException {
      if (_disposed || seq != _seq) return;
      _set(ReviewStage.failed, message: unexpectedAnswerText());
    } catch (_) {
      if (_disposed || seq != _seq) return;
      _set(ReviewStage.failed, message: couldNotReachServerText());
    }
  }

  @override
  Future<void> refreshTarget(String uuid) async {
    if (_disposed) return;
    final refreshed = [
      for (final t in _preview?.targets ?? const <PreviewedTarget>[])
        if (t.uuid == uuid) t.refreshed,
    ].firstOrNull;
    if (refreshed == null) return;
    _selection.refreshRevision(uuid, refreshed.baseRevision!);
    await requestPreview();
  }

  @override
  Future<void> removeTarget(String uuid) async {
    if (_disposed) return;
    _selection.deselect(uuid);
    if (_selection.count > 0) await requestPreview();
  }

  @override
  Future<bool> confirm(
    DeletionPreview shown, {
    required int confirmedCount,
  }) async {
    if (_disposed || _submitting) return false;
    if (!identical(shown, _preview) ||
        !shown.isFor(_candidates) ||
        _stage != ReviewStage.ready) {
      _set(_stage, message: reviewOutOfDateText());
      return false;
    }
    _submitting = true;
    _set(ReviewStage.submitting, keepMessage: true);
    try {
      final op = await _manager.submit(shown, confirmedCount: confirmedCount);
      if (_disposed) return true;
      _submittedOperation = op;
      _preview = null;
      _set(ReviewStage.submitted);
      _selection.clear();
      return true;
    } on DeletionAwaitingAnswer {
      _backToReady(shown, awaitingAnswerText());
    } on DeletionNotConfirmable {
      _preview = null;
      _afterFailure(ReviewStage.idle, reviewOutOfDateText());
    } on DeleteJobsUnavailable catch (e) {
      _preview = null;
      _afterFailure(ReviewStage.failed, confirmUnavailableText(e.reason));
    } catch (_) {
      _backToReady(shown, notSentText());
    } finally {
      _submitting = false;
    }
    return false;
  }

  void _backToReady(DeletionPreview shown, String message) {
    final stillCurrent = identical(_preview, shown) && shown.isFor(_candidates);
    if (!stillCurrent) _preview = null;
    _afterFailure(
      stillCurrent ? ReviewStage.ready : ReviewStage.idle,
      message,
    );
  }

  void _afterFailure(ReviewStage stage, String message) {
    if (!_disposed) _set(stage, message: message);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _selection.removeListener(_onSelectionChanged);
    _manager.jobs.removeListener(_onJobsChanged);
    _syncSub.close();
    super.dispose();
  }
}
