import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';

export 'package:frontend/services/uploads/upload_duplicate_banners.dart'
    show DuplicateGroup;

/// The one place a per-item duplicate decision lives.
class UploadDuplicateDecisions {
  /// item uuid -> (review version the choice was made at, chosen groups).
  final Map<String, (int, Set<DuplicateGroup>)> _chosen = {};

  void choose(UploadItem item, DuplicateGroup group) {
    final current = _chosen[item.itemUuid];
    final groups = current != null && current.$1 == item.reviewVersion
        ? current.$2
        : <DuplicateGroup>{};
    groups.add(group);
    _chosen[item.itemUuid] = (item.reviewVersion, groups);
  }

  Set<DuplicateGroup> chosenFor(UploadItem item) {
    final current = _chosen[item.itemUuid];
    if (current == null || current.$1 != item.reviewVersion) return {};
    return {...current.$2};
  }

  AcknowledgedDuplicates acknowledgementsFor(UploadItem item) {
    final check = item.duplicateCheck;
    final groups = chosenFor(item);
    if (check == null || !check.isReadable || groups.isEmpty) {
      return AcknowledgedDuplicates.none;
    }
    final library = <String>{};
    final staged = <String>{};
    for (final match in check.matches) {
      if (!match.isExact) continue;
      final subject = match.subject;
      if (subject is LibraryTrackSubject &&
          groups.contains(DuplicateGroup.library)) {
        library.add(subject.trackUuid);
      } else if (subject is StagedItemSubject &&
          groups.contains(DuplicateGroup.staged)) {
        staged.add(subject.itemUuid);
      }
    }
    return AcknowledgedDuplicates(libraryTracks: library, stagedItems: staged);
  }
}

final uploadDuplicateDecisionsProvider = Provider<UploadDuplicateDecisions>(
  (ref) => UploadDuplicateDecisions(),
);
