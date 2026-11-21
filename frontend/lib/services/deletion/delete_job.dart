// Phase 8 spec §4, §6 para 4: the local view of one delete job, built from
// the durable submission and the server's receipts. In memory only (O8).
import 'package:frontend/models/dto/library_tools_dtos.dart';

/// Where a job stands, as the user sees it.
enum DeleteJobPhase {
  /// Saved locally; not yet answered by the server.
  submitting,

  /// The answer was lost; the app is asking the server by the operation id
  /// before anything is sent again. A new submission is not possible.
  unconfirmed,

  /// The server refused the request for good ([DeleteJob.rejectionCode]).
  rejected,

  /// Accepted; no target started yet.
  accepted,

  /// Some targets are still being worked on.
  running,

  /// Every target was deleted (or was already deleted).
  completed,

  /// Finished; some targets were deleted and some were not.
  partial,

  /// Finished; no target was deleted.
  failed;

  bool get isTerminal =>
      this == rejected || this == completed || this == partial || this == failed;
}

/// One target's outcome.
enum DeleteItemStatus {
  pending,
  running,
  deleted,
  alreadyDeleted,
  conflict,
  busy,
  failed,

  /// A status this client does not know (kept, never coerced).
  unrecognized,
}

class DeleteJobItem {
  const DeleteJobItem({
    required this.uuid,
    required this.baseRevision,
    required this.status,
    required this.rawStatus,
    required this.errorCode,
    required this.tombstoneRevision,
    required this.details,
  });

  factory DeleteJobItem.fromDto(DeletionJobItemDto dto) => DeleteJobItem(
    uuid: dto.uuidId,
    baseRevision: dto.baseRevision,
    status: switch (dto.status) {
      'pending' => DeleteItemStatus.pending,
      'running' => DeleteItemStatus.running,
      'deleted' => DeleteItemStatus.deleted,
      'already_deleted' => DeleteItemStatus.alreadyDeleted,
      'conflict' => DeleteItemStatus.conflict,
      'busy' => DeleteItemStatus.busy,
      'failed' => DeleteItemStatus.failed,
      _ => DeleteItemStatus.unrecognized,
    },
    rawStatus: dto.status,
    errorCode: dto.error,
    tombstoneRevision: dto.tombstoneRevision,
    details: List.unmodifiable(dto.details),
  );

  final String uuid;
  final int baseRevision;
  final DeleteItemStatus status;
  final String rawStatus;

  /// The server's closed error code (`not_found`, `conflict`, `busy`,
  /// `path_rejected`, `rename`, `recovery_required`, `internal_error`) or
  /// null.
  final String? errorCode;
  final int? tombstoneRevision;
  final List<String> details;

  /// Deleted, or already deleted.
  bool get isGone =>
      status == DeleteItemStatus.deleted ||
      status == DeleteItemStatus.alreadyDeleted;

  bool get masterMissing => details.contains('master_missing');

  /// Deleted; the server still has to reclaim storage.
  bool get storageCleanupPending => details.contains('storage_cleanup_pending');
}

class DeleteJob {
  const DeleteJob({
    required this.operationUuid,
    required this.phase,
    required this.targets,
    this.items = const [],
    this.rejectionCode,
    this.createdAt,
    this.submittedAtMs,
  });

  final String operationUuid;
  final DeleteJobPhase phase;

  /// The frozen targets (uuid, base revision), in confirmation order; empty
  /// for a job known only from the server's receipt list until its first
  /// answer.
  final List<DeletionTargetDto> targets;

  /// The server's per-target outcomes (empty until accepted).
  final List<DeleteJobItem> items;
  final String? rejectionCode;

  /// Unix seconds, from the server's receipt.
  final int? createdAt;

  /// When this device stored the submission (UTC milliseconds, from
  /// `durable_submissions.created_at`); null for a job built from the
  /// server's answer.
  final int? submittedAtMs;
}
