// Phase 8 spec §4 para 3: what the server's preview says about each selected
// track, and whether the selection may be confirmed.
import 'package:frontend/models/dto/library_tools_dtos.dart';

/// A selected track as the caller holds it: the UUID and the revision the
/// app last saw (null: unknown, DEV-8-06; never 0).
class DeletionCandidate {
  const DeletionCandidate(this.uuid, this.baseRevision);
  final String uuid;
  final int? baseRevision;

  @override
  bool operator ==(Object other) =>
      other is DeletionCandidate &&
      other.uuid == uuid &&
      other.baseRevision == baseRevision;

  @override
  int get hashCode => Object.hash(uuid, baseRevision);

  @override
  String toString() => 'DeletionCandidate($uuid, $baseRevision)';
}

/// The preview's verdict on one target, in precedence order.
enum PreviewVerdict {
  /// No such track for this user (never confirmable).
  unknownTrack,

  /// Already deleted on the server: nothing to do.
  alreadyDeleted,

  /// The app does not know the revision it selected: refresh first.
  revisionUnknown,

  /// The track changed since it was selected: refresh or remove.
  conflict,

  /// The server is working on the track (edit, conversion, upload, another
  /// deletion): remove it or try later.
  busy,

  /// The catalog row exists but its file is missing: confirmable, as
  /// "Remove missing-file catalog entry".
  missingMaster,

  /// The server could not check the track's file (its existence is unknown):
  /// confirmable, and the server decides when it runs the deletion. Never
  /// shown as "ready" or as "missing".
  fileStatusUnknown,

  /// Confirmable.
  ready,
}

class PreviewedTarget {
  const PreviewedTarget({
    required this.uuid,
    required this.baseRevision,
    required this.serverRevision,
    required this.title,
    required this.artist,
    required this.album,
    required this.masterExists,
    required this.masterSize,
    required this.verdict,
  });

  final String uuid;

  /// The revision the selection carried (null: unknown).
  final int? baseRevision;

  /// The server's current revision (tombstone revision when already
  /// deleted); null when unknown.
  final int? serverRevision;
  final String? title;
  final String? artist;
  final String? album;
  final bool? masterExists;
  final int? masterSize;
  final PreviewVerdict verdict;

  bool get confirmable =>
      verdict == PreviewVerdict.ready ||
      verdict == PreviewVerdict.missingMaster ||
      verdict == PreviewVerdict.fileStatusUnknown;

  /// The candidate an explicit refresh would select instead (the server's
  /// revision), for a conflict or an unknown revision; null otherwise.
  DeletionCandidate? get refreshed {
    final server = serverRevision;
    final refreshable =
        verdict == PreviewVerdict.conflict ||
        verdict == PreviewVerdict.revisionUnknown;
    return refreshable && server != null
        ? DeletionCandidate(uuid, server)
        : null;
  }
}

/// The authoritative preview of one selection, in selection order.
class DeletionPreview {
  DeletionPreview(List<PreviewedTarget> targets)
    : targets = List.unmodifiable(targets);

  /// Pairs each candidate with the server's answer for it. A server answer
  /// that does not name exactly the requested tracks is a
  /// [FormatException].
  factory DeletionPreview.fromServer(
    List<DeletionCandidate> candidates,
    DeletionPreviewDto answer,
  ) {
    final byUuid = <String, DeletionPreviewTargetDto>{};
    for (final t in answer.targets) {
      if (byUuid.containsKey(t.uuidId)) {
        throw FormatException('preview names ${t.uuidId} twice');
      }
      byUuid[t.uuidId] = t;
    }
    final requested = {for (final c in candidates) c.uuid};
    if (requested.length != candidates.length ||
        byUuid.length != requested.length ||
        !byUuid.keys.every(requested.contains)) {
      throw const FormatException(
        'preview does not name exactly the requested tracks',
      );
    }
    return DeletionPreview([
      for (final c in candidates) _previewed(c, byUuid[c.uuid]!),
    ]);
  }

  final List<PreviewedTarget> targets;

  int get count => targets.length;

  /// This preview was made for exactly [candidates]: the same tracks, in the
  /// same order, with the same base revisions.
  bool isFor(List<DeletionCandidate> candidates) {
    if (candidates.length != targets.length) return false;
    for (var i = 0; i < targets.length; i++) {
      if (targets[i].uuid != candidates[i].uuid ||
          targets[i].baseRevision != candidates[i].baseRevision) {
        return false;
      }
    }
    return true;
  }

  /// Every target may be deleted as previewed.
  bool get confirmable =>
      targets.isNotEmpty && targets.every((t) => t.confirmable);
}

PreviewedTarget _previewed(DeletionCandidate c, DeletionPreviewTargetDto t) {
  final base = c.baseRevision;
  final PreviewVerdict verdict;
  if (t.unknown) {
    verdict = PreviewVerdict.unknownTrack;
  } else if (t.alreadyDeleted) {
    verdict = PreviewVerdict.alreadyDeleted;
  } else if (base == null) {
    // The server's conflict flag is not trusted for an unknown revision.
    verdict = PreviewVerdict.revisionUnknown;
  } else if (t.conflict || t.revision == null || t.revision != base) {
    verdict = PreviewVerdict.conflict;
  } else if (t.busy) {
    verdict = PreviewVerdict.busy;
  } else if (t.missingMaster) {
    verdict = PreviewVerdict.missingMaster;
  } else if (t.masterExists == null) {
    verdict = PreviewVerdict.fileStatusUnknown;
  } else {
    verdict = PreviewVerdict.ready;
  }
  return PreviewedTarget(
    uuid: c.uuid,
    baseRevision: base,
    serverRevision: t.revision,
    title: t.title,
    artist: t.artist,
    album: t.album,
    masterExists: t.masterExists,
    masterSize: t.masterSize,
    verdict: verdict,
  );
}
