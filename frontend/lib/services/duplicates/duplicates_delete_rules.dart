// Phase 8 spec §6 "Possible duplicates": the rules of "Delete this copy".
// When it is blocked (the other copy may be the last), what a pair's
// deletion status says, and whether a listed pair is still the pair a review
// was started on. Model code: nothing from ui/.
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/deletion_text.dart';

/// The one key of a pair: its two copies' UUIDs, in the server's order.
String pairKey(String uuidA, String uuidB) => '$uuidA|$uuidB';

/// A deletion of copy [uuid] submitted from the review of pair [pairKey];
/// [operation] is the submitted operation's ID.
typedef SubmittedCopyDeletion = ({
  String operation,
  String pairKey,
  String uuid,
});

/// The jobs that delete a copy of [pair], in [jobs]' order (oldest first).
List<DeleteJob> jobsDeletingCopyOf(
  DuplicatePairDto pair,
  Iterable<DeleteJob> jobs,
) => [
  for (final j in jobs)
    if (j.targets.any((t) => t.uuidId == pair.uuidA || t.uuidId == pair.uuidB))
      j,
];

DeleteJobItem? _itemOf(DeleteJob job, String uuid) {
  for (final i in job.items) {
    if (i.uuid == uuid) return i;
  }
  return null;
}

/// Only a rejection, or a finished job that positively says this copy was
/// not deleted (conflict, busy, failed), frees the pair. Anything else,
/// unrecognised outcomes included, keeps it blocked.
bool jobFreesCopy(DeleteJob job, String uuid) {
  if (job.phase == DeleteJobPhase.rejected) return true;
  if (!job.phase.isTerminal) return false;
  final item = _itemOf(job, uuid);
  return item != null &&
      (item.status == DeleteItemStatus.conflict ||
          item.status == DeleteItemStatus.busy ||
          item.status == DeleteItemStatus.failed);
}

/// [x] and [y] are the same pair in the same state: same copies, same
/// status, same revision of each copy.
bool sameDuplicatePairSnapshot(DuplicatePairDto x, DuplicatePairDto y) =>
    x.uuidA == y.uuidA &&
    x.uuidB == y.uuidB &&
    x.status == y.status &&
    x.trackA.revision == y.trackA.revision &&
    x.trackB.revision == y.trackB.revision;

/// Plain words for the newest of [jobs] that deletes a copy of [pair]: the
/// copy's outcome, else the rejection, else the job's state; null when
/// there is none.
String? duplicateDeleteStatus(DuplicatePairDto pair, Iterable<DeleteJob> jobs) {
  final mine = jobsDeletingCopyOf(pair, jobs);
  if (mine.isEmpty) return null;
  final job = mine.last;
  for (final i in job.items) {
    if (i.uuid == pair.uuidA || i.uuid == pair.uuidB) {
      return deleteItemOutcomeText(i);
    }
  }
  if (job.phase == DeleteJobPhase.rejected) {
    return deletionErrorText(job.rejectionCode);
  }
  return jobPhaseText(job.phase);
}

/// A submitted deletion concerns a pair when it was started on it or
/// deletes one of its copies (a track can be in several pairs).
bool _concerns(SubmittedCopyDeletion o, DuplicatePairDto pair) =>
    o.pairKey == pairKey(pair.uuidA, pair.uuidB) ||
    o.uuid == pair.uuidA ||
    o.uuid == pair.uuidB;

/// A copy of [pair] is being deleted, or was: neither copy may be deleted
/// again (the other may be the last copy). [jobs] are the session's jobs by
/// operation; [submitted] the deletions submitted that may not be in it yet.
/// [unfinishedKnown]: the server's unfinished deletions were read into
/// [jobs]; until then a deletion made before a relaunch or on another
/// device may be one of them, so every pair is blocked.
bool duplicateDeleteBlocked(
  DuplicatePairDto pair, {
  required Map<String, DeleteJob> jobs,
  required Iterable<SubmittedCopyDeletion> submitted,
  required bool unfinishedKnown,
}) {
  if (!unfinishedKnown) return true;
  // Submitted but not yet in the manager's map.
  for (final o in submitted) {
    if (_concerns(o, pair) && !jobs.containsKey(o.operation)) return true;
  }
  for (final job in jobsDeletingCopyOf(pair, jobs.values)) {
    for (final t in job.targets) {
      if ((t.uuidId == pair.uuidA || t.uuidId == pair.uuidB) &&
          !jobFreesCopy(job, t.uuidId)) {
        return true;
      }
    }
  }
  return false;
}
