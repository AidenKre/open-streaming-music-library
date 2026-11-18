// A fake DuplicatesControls for the page's widget tests (SC-26).
import 'package:flutter/foundation.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/duplicates/duplicates_header.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';

/// A row view built by the model rules, as the real controller builds it.
DuplicatePairView pairView(DuplicatePairDto p) {
  DuplicateCopyView copy(DuplicatePairTrackDto t) => DuplicateCopyView(
    track: t,
    fields: {
      for (final f in DuplicateField.values) f: duplicateFieldText(t, f),
    },
    identityLines: [...copyIdentityLines(t), copyIdLine(t.uuidId)],
  );
  return DuplicatePairView(
    pair: p,
    badge: duplicateBadgeText(p),
    isExact: isExactPair(p),
    a: copy(p.trackA),
    b: copy(p.trackB),
    differing: differingFields(p.trackA, p.trackB),
  );
}

class FakeDuplicatesControls extends ChangeNotifier
    implements DuplicatesControls {
  final calls = <String>[];

  @override
  DuplicatesFilter filter = DuplicatesFilter.open;
  @override
  DuplicatesLoad summaryLoad = DuplicatesLoad.loaded;
  @override
  DuplicatesHeader? header;
  @override
  DuplicatesLoad listLoad = DuplicatesLoad.loaded;
  @override
  List<DuplicatePairView> pairs = const [];
  @override
  bool hasMore = false;
  @override
  String unreachableText = 'Possible duplicates needs a connection';
  @override
  String? message;
  @override
  bool canPlay = true;
  @override
  String? previewingUuid;
  @override
  PreviewStatus previewStatus = PreviewStatus.idle;
  @override
  String? previewMessage;
  @override
  bool canDeleteCopy = false;

  /// What [startDeleteCopy] hands out (null: nothing can start).
  DeletionReviewControls? reviewToStart;

  /// The rows [setAside] / [undo] were given, in order.
  final asideRows = <DuplicatePairView>[];
  final undoRows = <DuplicatePairView>[];
  bool disposed = false;

  void notify() => notifyListeners();

  @override
  void setFilter(DuplicatesFilter filter) => calls.add('setFilter ${filter.name}');

  @override
  Future<void> loadMore() async => calls.add('loadMore');

  @override
  Future<void> refresh() async => calls.add('refresh');

  @override
  void clearMessage() => calls.add('clearMessage');

  /// What [setAside] answers (false: the row was stale, nothing done).
  bool setAsideResult = true;

  @override
  bool setAside(DuplicatePairView pair) {
    calls.add('setAside ${pair.key}');
    asideRows.add(pair);
    return setAsideResult;
  }

  /// Per pair key: the deletion status words, and blocked pairs.
  final deleteStatuses = <String, String>{};
  final blocked = <String>{};

  @override
  String? deleteStatus(DuplicatePairView pair) => deleteStatuses[pair.key];

  @override
  bool deleteBlocked(DuplicatePairView pair) => blocked.contains(pair.key);

  @override
  void undo(DuplicatePairView pair) {
    calls.add('undo ${pair.key}');
    undoRows.add(pair);
  }

  @override
  Future<void> togglePlay(String uuid) async => calls.add('togglePlay $uuid');

  @override
  void leave() => calls.add('leave');

  @override
  DeletionReviewControls? startDeleteCopy(
    DuplicatePairView pair,
    String uuid,
  ) {
    calls.add('startDeleteCopy ${pair.key} $uuid');
    return reviewToStart;
  }

  @override
  void endDeleteCopy(DeletionReviewControls review) =>
      calls.add('endDeleteCopy');

  @override
  void dispose() {
    calls.add('dispose');
    disposed = true;
    super.dispose();
  }
}
