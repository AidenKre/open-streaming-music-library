import 'package:flutter/foundation.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';

/// Scriptable Uploads page controller for widget tests.
class FakeUploadsControls extends ChangeNotifier implements UploadsControls {
  FakeUploadsControls({this.overview});

  @override
  UploadsOverview? overview;
  @override
  UploadsNotice? notice;
  @override
  bool adding = false;

  final calls = <String>[];

  /// Every visibility the page reported, in order.
  final visibility = <bool>[];
  bool disposed = false;
  final children = <String, ChildListState>{};

  void set({UploadsOverview? overview, UploadsNotice? notice, bool? adding}) {
    if (overview != null) this.overview = overview;
    this.notice = notice ?? this.notice;
    if (adding != null) this.adding = adding;
    notifyListeners();
  }

  void setChildren(String parent, ChildListState state) {
    children[parent] = state;
    notifyListeners();
  }

  @override
  void setPageVisible(bool visible) => visibility.add(visible);

  @override
  Future<void> addFiles() async => calls.add('addFiles');

  @override
  Future<void> cancel(String itemUuid) async => calls.add('cancel $itemUuid');

  @override
  Future<void> reselect(String itemUuid) async =>
      calls.add('reselect $itemUuid');

  @override
  Future<void> retry(String itemUuid) async => calls.add('retry $itemUuid');

  @override
  void dismissNotice() {
    calls.add('dismissNotice');
    notice = null;
    notifyListeners();
  }

  @override
  ChildListState? childrenOf(String parentItemUuid) => children[parentItemUuid];

  @override
  Future<void> loadChildren(
    String batchUuid,
    String parentItemUuid, {
    bool quiet = false,
  }) async => calls.add(
    'loadChildren $batchUuid/$parentItemUuid${quiet ? ' quiet' : ''}',
  );

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// A row with every field defaulted (tests override what they assert).
UploadRow fakeUploadRow(
  String uuid, {
  String name = 'song.flac',
  String batch = 'b-1',
  String status = 'Queued',
  String? detail,
  String? size = '10.0 MB',
  bool sending = false,
  int? sent,
  int? total = 10 * 1024 * 1024,
  bool attention = false,
  bool cancel = false,
  bool reselect = false,
  bool reviewTags = false,
  bool children = false,
  bool retry = false,
  bool enabled = true,
}) => UploadRow(
  itemUuid: uuid,
  batchUuid: batch,
  displayName: name,
  statusText: status,
  detailText: detail,
  sizeText: size,
  sending: sending,
  sentBytes: sent,
  totalBytes: total,
  needsAttention: attention,
  offersCancel: cancel,
  offersReselect: reselect,
  offersReviewTags: reviewTags,
  offersChildren: children,
  canCancel: cancel && enabled,
  canReselect: reselect && enabled,
  canReviewTags: reviewTags && enabled,
  canOpenChildren: children && enabled,
  offersRetry: retry,
  canRetry: retry && enabled,
);

UploadsOverview fakeUploadsOverview(
  List<UploadRow> rows, {
  UploadsAvailability availability = UploadsAvailability.available,
  String? limits,
  UploadCounts? counts,
  Set<String> otherDeviceSending = const {},
  bool transfersPaused = false,
}) => UploadsOverview(
  availability: availability,
  otherDeviceSending: otherDeviceSending,
  transfersPaused: transfersPaused,
  rows: rows,
  counts:
      counts ??
      UploadCounts(
        total: rows.length,
        inProgress: rows.length,
        readyForReview: 0,
        needsAttention: 0,
        done: 0,
        cancelled: 0,
        expired: 0,
      ),
  limitsText: limits,
);
