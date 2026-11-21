/// Library tools API DTOs (Phase 8 spec §4), mirroring the server as built
/// (`backend/app/models/deletions.py`, `duplicates.py`). Parsing ignores
/// unknown fields; a required field missing or of the wrong type is a
/// [FormatException]; null is unknown (never 0/false); status and code
/// strings are kept as sent.
library;

import 'dart:convert';

import 'package:frontend/models/dto/json_fields.dart';

// ── Deletions ─────────────────────────────────────────────────────────────

class DeletionTargetDto {
  const DeletionTargetDto({required this.uuidId, required this.baseRevision});
  final String uuidId;
  final int baseRevision;

  factory DeletionTargetDto.fromJson(Object? json) {
    final m = jsonObject(json, 'deletion target');
    return DeletionTargetDto(
      uuidId: jsonString(m, 'uuid_id'),
      baseRevision: jsonInt(m, 'base_revision'),
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid_id': uuidId,
    'base_revision': baseRevision,
  };
}

class DeletionPreviewRequestDto {
  const DeletionPreviewRequestDto({required this.targets});
  final List<DeletionTargetDto> targets;

  Map<String, dynamic> toJson() => {
    'targets': [for (final t in targets) t.toJson()],
  };
}

class DeletionJobRequestDto {
  const DeletionJobRequestDto({
    required this.operationUuid,
    required this.targets,
    required this.confirmedCount,
  });
  final String operationUuid;
  final List<DeletionTargetDto> targets;
  final int confirmedCount;

  Map<String, dynamic> toJson() => {
    'operation_uuid': operationUuid,
    'targets': [for (final t in targets) t.toJson()],
    'confirmed_count': confirmedCount,
  };

  /// The exact request text, encoded once and reused on every retry.
  String toFrozenJson() => jsonEncode(toJson());

  /// The targets of a request text written by [toFrozenJson]; text that is
  /// not such a request is a [FormatException].
  static List<DeletionTargetDto> targetsOfFrozenJson(String frozenJson) {
    final m = jsonObject(jsonDecode(frozenJson), 'deletion request');
    return [
      for (final t in jsonList(m, 'targets')) DeletionTargetDto.fromJson(t),
    ];
  }
}

class DeletionPreviewTargetDto {
  const DeletionPreviewTargetDto({
    required this.uuidId,
    required this.baseRevision,
    required this.revision,
    required this.title,
    required this.artist,
    required this.album,
    required this.masterExists,
    required this.masterSize,
    required this.unknown,
    required this.alreadyDeleted,
    required this.missingMaster,
    required this.conflict,
    required this.busy,
  });
  final String uuidId;
  final int baseRevision;
  final int? revision;
  final String? title;
  final String? artist;
  final String? album;
  final bool? masterExists;
  final int? masterSize;
  final bool unknown;
  final bool alreadyDeleted;
  final bool missingMaster;
  final bool conflict;
  final bool busy;

  factory DeletionPreviewTargetDto.fromJson(Object? json) {
    final m = jsonObject(json, 'preview target');
    return DeletionPreviewTargetDto(
      uuidId: jsonString(m, 'uuid_id'),
      baseRevision: jsonInt(m, 'base_revision'),
      revision: jsonIntOrNull(m, 'revision'),
      title: jsonStringOrNull(m, 'title'),
      artist: jsonStringOrNull(m, 'artist'),
      album: jsonStringOrNull(m, 'album'),
      masterExists: jsonBoolOrNull(m, 'master_exists'),
      masterSize: jsonIntOrNull(m, 'master_size'),
      unknown: jsonBool(m, 'unknown'),
      alreadyDeleted: jsonBool(m, 'already_deleted'),
      missingMaster: jsonBool(m, 'missing_master'),
      conflict: jsonBool(m, 'conflict'),
      busy: jsonBool(m, 'busy'),
    );
  }
}

class DeletionPreviewDto {
  const DeletionPreviewDto({required this.targets});
  final List<DeletionPreviewTargetDto> targets;

  factory DeletionPreviewDto.fromJson(Object? json) {
    final m = jsonObject(json, 'deletion preview');
    return DeletionPreviewDto(
      targets: [
        for (final t in jsonList(m, 'targets'))
          DeletionPreviewTargetDto.fromJson(t),
      ],
    );
  }
}

class DeletionJobItemDto {
  const DeletionJobItemDto({
    required this.uuidId,
    required this.baseRevision,
    required this.status,
    required this.error,
    required this.tombstoneRevision,
    required this.details,
  });
  final String uuidId;
  final int baseRevision;
  final String status;
  final String? error;
  final int? tombstoneRevision;
  final List<String> details;

  factory DeletionJobItemDto.fromJson(Object? json) {
    final m = jsonObject(json, 'deletion job item');
    return DeletionJobItemDto(
      uuidId: jsonString(m, 'uuid_id'),
      baseRevision: jsonInt(m, 'base_revision'),
      status: jsonString(m, 'status'),
      error: jsonStringOrNull(m, 'error'),
      tombstoneRevision: jsonIntOrNull(m, 'tombstone_revision'),
      details: jsonStringList(m, 'details'),
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid_id': uuidId,
    'base_revision': baseRevision,
    'status': status,
    'error': error,
    'tombstone_revision': tombstoneRevision,
    'details': details,
  };
}

class DeletionJobDto {
  const DeletionJobDto({
    required this.operationUuid,
    required this.createdAt,
    required this.status,
    required this.itemCount,
    required this.items,
  });
  final String operationUuid;
  final int createdAt;
  final String status;
  final int itemCount;
  final List<DeletionJobItemDto> items;

  factory DeletionJobDto.fromJson(Object? json) {
    final m = jsonObject(json, 'deletion job');
    return DeletionJobDto(
      operationUuid: jsonString(m, 'operation_uuid'),
      createdAt: jsonInt(m, 'created_at'),
      status: jsonString(m, 'status'),
      itemCount: jsonInt(m, 'item_count'),
      items: [
        for (final i in jsonList(m, 'items')) DeletionJobItemDto.fromJson(i),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'operation_uuid': operationUuid,
    'created_at': createdAt,
    'status': status,
    'item_count': itemCount,
    'items': [for (final i in items) i.toJson()],
  };
}

class DeletionJobSummaryDto {
  const DeletionJobSummaryDto({
    required this.operationUuid,
    required this.createdAt,
    required this.status,
    required this.itemCount,
    required this.stateCounts,
  });
  final String operationUuid;
  final int createdAt;
  final String status;
  final int itemCount;
  final Map<String, int> stateCounts;

  factory DeletionJobSummaryDto.fromJson(Object? json) {
    final m = jsonObject(json, 'deletion job summary');
    return DeletionJobSummaryDto(
      operationUuid: jsonString(m, 'operation_uuid'),
      createdAt: jsonInt(m, 'created_at'),
      status: jsonString(m, 'status'),
      itemCount: jsonInt(m, 'item_count'),
      stateCounts: jsonIntMap(m, 'state_counts'),
    );
  }
}

class DeletionJobPageDto {
  const DeletionJobPageDto({required this.jobs, required this.nextAfter});
  final List<DeletionJobSummaryDto> jobs;
  final String? nextAfter;

  factory DeletionJobPageDto.fromJson(Object? json) {
    final m = jsonObject(json, 'deletion job page');
    return DeletionJobPageDto(
      jobs: [
        for (final j in jsonList(m, 'jobs')) DeletionJobSummaryDto.fromJson(j),
      ],
      nextAfter: jsonStringOrNull(m, 'next_after'),
    );
  }
}

// ── Duplicates (8A.4; consumed by 8B.3) ───────────────────────────────────
// Pairs and the dismiss/restore answer are strict; the summary is lenient per
// count (a missing or non-int count is null, never 0).

/// A summary count: an `int`, else null (unknown). [obj] may be anything.
int? _count(Object? obj, String key) {
  if (obj is! Map) return null;
  final v = obj[key];
  return v is int ? v : null;
}

Object? _sub(Object? obj, String key) => obj is Map ? obj[key] : null;

class DuplicatePairTrackDto {
  const DuplicatePairTrackDto({
    required this.uuidId,
    required this.revision,
    required this.title,
    required this.artist,
    required this.album,
    required this.codec,
    required this.bitrateKbps,
    required this.sampleRateHz,
    required this.channels,
    required this.durationS,
    required this.addedAt,
    required this.masterPresent,
  });
  final String uuidId;
  final int revision;
  final String? title;
  final String? artist;
  final String? album;
  final String? codec;
  final double? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final double? durationS;
  final int addedAt;
  final bool? masterPresent;

  factory DuplicatePairTrackDto.fromJson(Object? json) {
    final m = jsonObject(json, 'duplicate track');
    return DuplicatePairTrackDto(
      uuidId: jsonString(m, 'uuid_id'),
      revision: jsonInt(m, 'revision'),
      title: jsonStringOrNull(m, 'title'),
      artist: jsonStringOrNull(m, 'artist'),
      album: jsonStringOrNull(m, 'album'),
      codec: jsonStringOrNull(m, 'codec'),
      bitrateKbps: jsonDoubleOrNull(m, 'bitrate_kbps'),
      sampleRateHz: jsonIntOrNull(m, 'sample_rate_hz'),
      channels: jsonIntOrNull(m, 'channels'),
      durationS: jsonDoubleOrNull(m, 'duration_s'),
      addedAt: jsonInt(m, 'added_at'),
      masterPresent: jsonBoolOrNull(m, 'master_present'),
    );
  }
}

class DuplicatePairDto {
  const DuplicatePairDto({
    required this.uuidA,
    required this.uuidB,
    required this.kind,
    required this.band,
    required this.score,
    required this.status,
    required this.detectedAt,
    required this.trackA,
    required this.trackB,
  });
  final String uuidA;
  final String uuidB;
  final String kind;
  final String band;
  final double? score;
  final String status;
  final int detectedAt;
  final DuplicatePairTrackDto trackA;
  final DuplicatePairTrackDto trackB;

  factory DuplicatePairDto.fromJson(Object? json) {
    final m = jsonObject(json, 'duplicate pair');
    return DuplicatePairDto(
      uuidA: jsonString(m, 'uuid_a'),
      uuidB: jsonString(m, 'uuid_b'),
      kind: jsonString(m, 'kind'),
      band: jsonString(m, 'band'),
      score: jsonDoubleOrNull(m, 'score'),
      status: jsonString(m, 'status'),
      detectedAt: jsonInt(m, 'detected_at'),
      trackA: DuplicatePairTrackDto.fromJson(m['track_a']),
      trackB: DuplicatePairTrackDto.fromJson(m['track_b']),
    );
  }
}

class DuplicatePairPageDto {
  const DuplicatePairPageDto({required this.pairs, required this.nextAfter});
  final List<DuplicatePairDto> pairs;
  final String? nextAfter;

  factory DuplicatePairPageDto.fromJson(Object? json) {
    final m = jsonObject(json, 'duplicate page');
    return DuplicatePairPageDto(
      pairs: [
        for (final p in jsonList(m, 'pairs')) DuplicatePairDto.fromJson(p),
      ],
      nextAfter: jsonStringOrNull(m, 'next_after'),
    );
  }
}

class DuplicateBandCountsDto {
  const DuplicateBandCountsDto({this.open, this.dismissed});
  final int? open;
  final int? dismissed;

  factory DuplicateBandCountsDto.fromJson(Object? json) =>
      DuplicateBandCountsDto(
        open: _count(json, 'open'),
        dismissed: _count(json, 'dismissed'),
      );
}

class ExactCoverageDto {
  const ExactCoverageDto({
    this.pending,
    this.current,
    this.failed,
    this.unsupported,
  });
  final int? pending;
  final int? current;
  final int? failed;
  final int? unsupported;

  factory ExactCoverageDto.fromJson(Object? json) => ExactCoverageDto(
    pending: _count(json, 'pending'),
    current: _count(json, 'current'),
    failed: _count(json, 'failed'),
    unsupported: _count(json, 'unsupported'),
  );
}

class FingerprintCoverageDto {
  const FingerprintCoverageDto({
    this.pending,
    this.current,
    this.unavailable,
    this.tooShort,
    this.lowInformation,
    this.failed,
  });
  final int? pending;
  final int? current;
  final int? unavailable;
  final int? tooShort;
  final int? lowInformation;
  final int? failed;

  factory FingerprintCoverageDto.fromJson(Object? json) =>
      FingerprintCoverageDto(
        pending: _count(json, 'pending'),
        current: _count(json, 'current'),
        unavailable: _count(json, 'unavailable'),
        tooShort: _count(json, 'too_short'),
        lowInformation: _count(json, 'low_information'),
        failed: _count(json, 'failed'),
      );
}

class MatchCoverageDto {
  const MatchCoverageDto({this.pending, this.current});
  final int? pending;
  final int? current;

  factory MatchCoverageDto.fromJson(Object? json) => MatchCoverageDto(
    pending: _count(json, 'pending'),
    current: _count(json, 'current'),
  );
}

class DuplicateSummaryDto {
  const DuplicateSummaryDto({
    required this.exact,
    required this.strong,
    required this.possible,
    required this.exactCoverage,
    required this.fingerprintCoverage,
    required this.matchCoverage,
    required this.fingerprinter,
  });
  final DuplicateBandCountsDto exact;
  final DuplicateBandCountsDto strong;
  final DuplicateBandCountsDto possible;
  final ExactCoverageDto exactCoverage;
  final FingerprintCoverageDto fingerprintCoverage;
  final MatchCoverageDto matchCoverage;
  final String? fingerprinter;

  factory DuplicateSummaryDto.fromJson(Object? json) {
    final m = jsonObject(json, 'duplicate summary');
    final bands = m['bands'];
    final coverage = m['coverage'];
    return DuplicateSummaryDto(
      exact: DuplicateBandCountsDto.fromJson(_sub(bands, 'exact')),
      strong: DuplicateBandCountsDto.fromJson(_sub(bands, 'strong')),
      possible: DuplicateBandCountsDto.fromJson(_sub(bands, 'possible')),
      exactCoverage: ExactCoverageDto.fromJson(_sub(coverage, 'exact')),
      fingerprintCoverage: FingerprintCoverageDto.fromJson(
        _sub(coverage, 'fingerprint'),
      ),
      matchCoverage: MatchCoverageDto.fromJson(_sub(coverage, 'match')),
      fingerprinter: jsonStringOrNull(m, 'fingerprinter'),
    );
  }
}

class DuplicatePairStatusDto {
  const DuplicatePairStatusDto({
    required this.uuidA,
    required this.uuidB,
    required this.status,
  });
  final String uuidA;
  final String uuidB;
  final String status;

  factory DuplicatePairStatusDto.fromJson(Object? json) {
    final m = jsonObject(json, 'duplicate pair status');
    return DuplicatePairStatusDto(
      uuidA: jsonString(m, 'uuid_a'),
      uuidB: jsonString(m, 'uuid_b'),
      status: jsonString(m, 'status'),
    );
  }
}
