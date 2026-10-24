import 'package:flutter/foundation.dart';

/// Lifecycle state of a [ConversionJob], mirroring [DownloadStatus]'s sealed
/// shape (`lib/services/download/download_queue.dart`) 1:1 with the backend's
/// job status enum. Prefixed `Conversion*` (unlike `DownloadStatus`'s bare
/// `Queued`/`Failed`) to avoid a top-level name collision where both are
/// imported together (e.g. a track row showing both download and conversion
/// state).
sealed class ConversionStatus {
  const ConversionStatus();
}

class ConversionQueued extends ConversionStatus {
  const ConversionQueued();
}

class ConversionRunning extends ConversionStatus {
  const ConversionRunning();
}

class ConversionDone extends ConversionStatus {
  const ConversionDone();
}

class ConversionFailed extends ConversionStatus {
  final String message;
  const ConversionFailed({required this.message});
}

class ConversionCancelled extends ConversionStatus {
  const ConversionCancelled();
}

/// Client-side snapshot of one backend conversion job (`JobResponse`).
@immutable
class ConversionJob {
  final int jobId;
  final String uuidId;
  final String targetCodec;
  final String targetContainer;
  final int? targetBitrate;
  final ConversionStatus status;

  const ConversionJob({
    required this.jobId,
    required this.uuidId,
    required this.targetCodec,
    required this.targetContainer,
    required this.status,
    this.targetBitrate,
  });

  bool get isQueued => status is ConversionQueued;
  bool get isRunning => status is ConversionRunning;
  bool get isDone => status is ConversionDone;
  bool get isFailed => status is ConversionFailed;
  bool get isCancelled => status is ConversionCancelled;

  /// Still occupying a slot in the backend's scheduler.
  bool get isActive => isQueued || isRunning;

  /// Reached an end state; polling for this job can stop.
  bool get isTerminal => isDone || isFailed || isCancelled;

  ConversionJob withStatus(ConversionStatus status) => ConversionJob(
    jobId: jobId,
    uuidId: uuidId,
    targetCodec: targetCodec,
    targetContainer: targetContainer,
    targetBitrate: targetBitrate,
    status: status,
  );

  factory ConversionJob.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status'] as String) {
      'queued' => const ConversionQueued(),
      'running' => const ConversionRunning(),
      'done' => const ConversionDone(),
      'cancelled' => const ConversionCancelled(),
      'failed' => ConversionFailed(
        message: json['error_text'] as String? ?? 'Conversion failed',
      ),
      final other => throw FormatException('unknown job status: $other'),
    };
    return ConversionJob(
      jobId: json['job_id'] as int,
      uuidId: json['uuid_id'] as String,
      targetCodec: json['target_codec'] as String,
      targetContainer: json['target_container'] as String,
      targetBitrate: json['target_bitrate'] as int?,
      status: status,
    );
  }
}
