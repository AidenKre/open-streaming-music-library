import 'package:flutter/foundation.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_duplicate_summary.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';

import '../helpers/fake_uploads_api.dart' show itemJson;
import '../helpers/upload_intent_record.dart';

/// Scriptable review controller for widget tests.
class FakeUploadReviewControls extends ChangeNotifier
    implements UploadReviewControls {
  final calls = <String>[];

  @override
  ReviewLoad load = ReviewLoad.ready;
  @override
  int position = 0;
  @override
  int total = 0;
  @override
  ReviewItemView? current;
  @override
  MetadataEdit edit = const MetadataEdit.empty();
  Map<String, Object?> detected = const {};
  @override
  List<FieldDescriptor> fields = defaultEditableTrackFields;
  @override
  bool busy = false;
  @override
  bool canPrevious = false;
  @override
  bool canNext = false;
  @override
  bool moreItemsReady = false;
  @override
  TrackUI? currentTrack;
  @override
  ReviewImported? lastImported;
  @override
  String? notice;

  @override
  String get positionText => total == 0 ? '' : '${position + 1}/$total';

  /// Shows [view] at [position] of [total] with its draft and detected tags.
  void show(
    ReviewItemView view, {
    int position = 0,
    int total = 1,
    MetadataEdit edit = const MetadataEdit.empty(),
    Map<String, Object?> detected = const {},
    bool canPrevious = false,
    bool canNext = false,
  }) {
    current = view;
    this.position = position;
    this.total = total;
    this.edit = edit;
    this.detected = detected;
    this.canPrevious = canPrevious;
    this.canNext = canNext;
    notifyListeners();
  }

  void changed() => notifyListeners();

  @override
  Object? detectedValue(String key) => detected[key];

  @override
  Future<void> start(String batchUuid, {String? startAt}) async =>
      calls.add('start $batchUuid ${startAt ?? '-'}');
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> previous() async => calls.add('previous');
  @override
  void editChanged(MetadataEdit edit) {
    calls.add('edit ${edit.toPayload()}');
    this.edit = edit;
    notifyListeners();
  }

  /// The (item, review version) each confirm was sent for.
  final confirmTargets = <(String, int)>[];

  @override
  Future<void> confirm({
    required String itemUuid,
    required int reviewVersion,
    required bool writeTags,
  }) async {
    confirmTargets.add((itemUuid, reviewVersion));
    calls.add('confirm $writeTags');
  }
  @override
  Future<void> skip() async => calls.add('skip');
  @override
  Future<void> cancelItem() async => calls.add('cancel');
  @override
  Future<void> refresh() async => calls.add('refresh');
  @override
  Future<List<String>> suggestions(String key, String query) async => [];
  @override
  void dismissNotice() {
    calls.add('dismissNotice');
    notice = null;
    notifyListeners();
  }

  @override
  DuplicateSummary? duplicateSummary;
  @override
  void chooseDuplicates(DuplicateGroup group) =>
      calls.add('choose ${group.name}');
  @override
  Future<void> useExisting() async => calls.add('useExisting');
  @override
  Future<void> dontImport() async => calls.add('dontImport');
  @override
  Future<void> backToReview() async => calls.add('backToReview');

  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// A review view for [uuid] in [state] (through the real rules).
ReviewItemView fakeReviewView(
  String uuid, {
  String state = 'review_ready',
  String? code,
  int version = 1,
  bool? tagWrite = true,
  bool online = true,
  String? result,
  Map<String, dynamic>? check,
  List<Map<String, dynamic>>? conflicts,
  Map<String, dynamic>? detected,
  Set<DuplicateGroup> chosen = const {},
}) => ReviewItemView.of(
  item: UploadItem.fromJson({
    ...itemJson(
      uuid,
      filename: '$uuid.flac',
      state: state,
      expectedBytes: 3,
      receivedBytes: 3,
      reviewVersion: version,
    ),
    'tag_write_supported': tagWrite,
    'result_track_uuid': result,
    'duplicate_check': check,
    'conflict_matches': conflicts,
    'detected_metadata': detected,
  }),
  intent: intentRecord(
    uuid,
    batchUuid: 'b-1',
    displayName: '$uuid.flac',
    state: state,
    lastErrorCode: code,
    localBindingId: 'bind',
  ),
  online: online,
  chosen: chosen,
);
