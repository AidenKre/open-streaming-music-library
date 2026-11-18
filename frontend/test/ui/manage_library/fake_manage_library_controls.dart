import 'package:flutter/foundation.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

import '../fake_track_selection_controls.dart';

/// A [DeletionReviewControls] for widget tests (SC-26): settable state, every
/// input recorded in [calls] (`requestPreview`, `refreshTarget <uuid>`,
/// `removeTarget <uuid>`, `confirm <count>`, `dispose`).
class FakeDeletionReviewControls extends ChangeNotifier
    implements DeletionReviewControls {
  @override
  ReviewStage stage = ReviewStage.idle;
  @override
  DeletionPreview? preview;
  @override
  String? message;
  @override
  String? blockedReason;
  @override
  bool canConfirm = true;
  @override
  String? submittedOperation;
  @override
  bool nothingToReview = false;

  final calls = <String>[];

  /// The preview object the last [confirm] was given.
  DeletionPreview? confirmedShown;
  int? confirmedCount;

  /// What [confirm] answers; [messageAfterConfirm] is set as [message] first.
  bool confirmResult = true;
  String? messageAfterConfirm;
  bool _disposed = false;

  void notify() => notifyListeners();

  @override
  Future<void> requestPreview() async => calls.add('requestPreview');

  @override
  Future<void> refreshTarget(String uuid) async =>
      calls.add('refreshTarget $uuid');

  @override
  Future<void> removeTarget(String uuid) async =>
      calls.add('removeTarget $uuid');

  @override
  Future<bool> confirm(
    DeletionPreview shown, {
    required int confirmedCount,
  }) async {
    calls.add('confirm $confirmedCount');
    confirmedShown = shown;
    this.confirmedCount = confirmedCount;
    if (!confirmResult) {
      message = messageAfterConfirm;
      notifyListeners();
    }
    return confirmResult;
  }

  @override
  void dispose() {
    calls.add('dispose');
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

/// A [ManageLibraryControls] for widget tests: settable state, inputs
/// recorded in [calls].
class FakeManageLibraryControls extends ChangeNotifier
    implements ManageLibraryControls {
  FakeManageLibraryControls({
    this.availability = ServerDeleteAvailability.enabled,
    FakeDeletionReviewControls? review,
    FakeTrackSelectionControls? selection,
  }) : fakeReview = review ?? FakeDeletionReviewControls(),
       fakeSelection = selection ?? FakeTrackSelectionControls();

  final FakeDeletionReviewControls fakeReview;
  final FakeTrackSelectionControls fakeSelection;

  @override
  ServerDeleteAvailability availability;
  @override
  List<SelectedItemView> selectedItems = const [];
  @override
  List<DeleteJobView> jobs = const [];
  @override
  ReceiptsLoad receiptsLoad = ReceiptsLoad.idle;
  @override
  String receiptsUnreachableText = 'Deletion history needs a connection.';
  @override
  List<ReceiptView> receipts = const [];
  @override
  bool hasMoreReceipts = false;

  final calls = <String>[];
  bool _disposed = false;

  @override
  TrackSelectionControls get selection => fakeSelection;

  @override
  DeletionReviewControls get review => fakeReview;

  /// Selects [entries] in the fake selection (so the page's own count and
  /// the browse rows agree) and lists them in [selectedItems].
  void select(List<SelectedItemView> entries) {
    fakeSelection.clear();
    fakeSelection.calls.clear();
    for (final e in entries) {
      fakeSelection.toggle(
        TrackUI(
          uuidId: e.uuid,
          createdAt: 0,
          lastUpdated: 0,
          revision: 1,
          duration: null,
          bitrateKbps: null,
          sampleRateHz: null,
          channels: null,
          hasAlbumArt: false,
        ),
      );
    }
    fakeSelection.calls.clear();
    selectedItems = entries;
    notifyListeners();
  }

  void notify() => notifyListeners();

  @override
  void removeSelected(String uuid) => calls.add('removeSelected $uuid');

  @override
  void clearSelection() => calls.add('clearSelection');

  @override
  Future<void> loadReceipts() async => calls.add('loadReceipts');

  @override
  Future<void> loadMoreReceipts() async => calls.add('loadMoreReceipts');

  @override
  Future<void> retryReceipts() async => calls.add('retryReceipts');

  @override
  void openReceipt(String operationUuid) => calls.add('openReceipt $operationUuid');

  @override
  void dispose() {
    calls.add('dispose');
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
