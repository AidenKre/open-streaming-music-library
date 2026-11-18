/// Upload API DTOs (Phase 7 spec §4), mirroring the server as built
/// (`backend/app/models/uploads.py`): snake_case wire names, times in unix
/// seconds. Parsing ignores unknown fields; a required field that is missing
/// or of the wrong type is a [FormatException]; a nullable field keeps null
/// as unknown (never 0).
library;

import 'dart:convert';

import 'package:frontend/models/dto/json_fields.dart';
import 'package:frontend/models/feature_blocks.dart';

/// An item's last error (`{code, message?, retryable?}`).
class UploadItemError {
  const UploadItemError({required this.code, this.message, this.retryable});
  final String code;
  final String? message;

  /// Null: the server didn't say.
  final bool? retryable;

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'retryable': retryable,
  };
}

/// `GET /tracks/uploads/items/{item}` and every item list entry.
class UploadItem {
  const UploadItem({
    required this.itemUuid,
    required this.batchUuid,
    required this.parentItemUuid,
    required this.filename,
    required this.selectionIndex,
    required this.memberOrderKey,
    required this.rawState,
    required this.expectedBytes,
    required this.expectedSha256,
    required this.receivedBytes,
    required this.reviewVersion,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
    required this.duplicateCheck,
    this.kind,
    this.skippedMembers,
    this.detectedMetadata,
    this.tagWriteSupported,
    this.resultTrackUuid,
    this.resultRevision,
    this.duplicateKind,
    this.conflictMatches,
  });

  factory UploadItem.fromJson(Object? json) {
    final m = jsonObject(json, 'upload item');
    final errorJson = m['error'];
    final Map<String, dynamic>? err = errorJson == null
        ? null
        : jsonObject(errorJson, 'error');
    final retryable = err?['retryable'];
    if (retryable != null && retryable is! bool) {
      throw const FormatException('retryable must be a boolean or null');
    }
    final duplicate = m['duplicate_check'];
    final detected = m['detected_metadata'];
    final conflicts = m['conflict_matches'];
    return UploadItem(
      itemUuid: jsonString(m, 'item_uuid'),
      batchUuid: jsonString(m, 'batch_uuid'),
      parentItemUuid: jsonStringOrNull(m, 'parent_item_uuid'),
      filename: jsonString(m, 'filename'),
      selectionIndex: jsonInt(m, 'selection_index'),
      memberOrderKey: jsonString(m, 'member_order_key'),
      rawState: jsonString(m, 'state'),
      expectedBytes: jsonIntOrNull(m, 'expected_bytes'),
      expectedSha256: jsonStringOrNull(m, 'expected_sha256'),
      receivedBytes: jsonInt(m, 'received_bytes'),
      reviewVersion: jsonInt(m, 'review_version'),
      error: err == null
          ? null
          : UploadItemError(
              code: jsonString(err, 'code'),
              message: jsonStringOrNull(err, 'message'),
              retryable: retryable as bool?,
            ),
      createdAt: jsonInt(m, 'created_at'),
      updatedAt: jsonInt(m, 'updated_at'),
      duplicateCheck: duplicate == null
          ? null
          : DuplicateCheck.fromJson(duplicate),
      kind: jsonStringOrNull(m, 'kind'),
      skippedMembers: jsonIntOrNull(m, 'skipped_members'),
      detectedMetadata: detected == null
          ? null
          : DetectedMetadata.fromJson(detected),
      tagWriteSupported: jsonBoolOrNull(m, 'tag_write_supported'),
      resultTrackUuid: jsonStringOrNull(m, 'result_track_uuid'),
      resultRevision: jsonIntOrNull(m, 'result_revision'),
      duplicateKind: jsonStringOrNull(m, 'duplicate_kind'),
      conflictMatches: conflicts == null
          ? null
          : [for (final x in jsonList(m, 'conflict_matches')) DuplicateMatch.fromJson(x)],
    );
  }

  final String itemUuid;
  final String batchUuid;
  final String? parentItemUuid;
  final String filename;
  final int selectionIndex;
  final String memberOrderKey;

  /// The state exactly as the server sent it.
  final String rawState;
  final int? expectedBytes;
  final String? expectedSha256;
  final int receivedBytes;
  final int reviewVersion;
  final UploadItemError? error;

  /// Unix seconds.
  final int createdAt;
  final int updatedAt;

  /// Null: not checked yet (or a server without the field).
  final DuplicateCheck? duplicateCheck;

  /// `audio` or `zip` (raw); null: unknown (or a server without the field).
  final String? kind;

  /// ZIP parents: members skipped on expansion. Null: unknown, never 0.
  final int? skippedMembers;

  /// Null: not detected yet (or a server without the field).
  final DetectedMetadata? detectedMetadata;

  /// Null: unknown, neither supported nor unsupported.
  final bool? tagWriteSupported;

  /// The track an imported (or duplicate-closed) item resulted in.
  final String? resultTrackUuid;
  final int? resultRevision;

  /// `exact` or `fingerprint` (raw) on a duplicate-closed item.
  final String? duplicateKind;

  /// The library tracks a `duplicate_conflict` item conflicts with.
  final List<DuplicateMatch>? conflictMatches;

  Map<String, dynamic> toJson() => {
    'item_uuid': itemUuid,
    'batch_uuid': batchUuid,
    'parent_item_uuid': parentItemUuid,
    'filename': filename,
    'selection_index': selectionIndex,
    'member_order_key': memberOrderKey,
    'state': rawState,
    'expected_bytes': expectedBytes,
    'expected_sha256': expectedSha256,
    'received_bytes': receivedBytes,
    'review_version': reviewVersion,
    'error': error?.toJson(),
    'created_at': createdAt,
    'updated_at': updatedAt,
    'duplicate_check': duplicateCheck?.toJson(),
    'kind': kind,
    'skipped_members': skippedMembers,
    'detected_metadata': detectedMetadata?.toJson(),
    'tag_write_supported': tagWriteSupported,
    'result_track_uuid': resultTrackUuid,
    'result_revision': resultRevision,
    'duplicate_kind': duplicateKind,
    'conflict_matches': conflictMatches == null
        ? null
        : [for (final x in conflictMatches!) x.toJson()],
  };
}

/// A batch summary (`GET /tracks/uploads/{batch}` and list entries).
class UploadBatch {
  const UploadBatch({
    required this.batchUuid,
    required this.label,
    required this.createdAt,
    required this.updatedAt,
    required this.itemCount,
    required this.stateCounts,
    required this.itemsPath,
  });

  factory UploadBatch.fromJson(Object? json) {
    final m = jsonObject(json, 'upload batch');
    final counts = m['state_counts'];
    if (counts is! Map) {
      throw const FormatException('state_counts must be an object');
    }
    final stateCounts = <String, int>{};
    for (final e in counts.entries) {
      final k = e.key;
      final v = e.value;
      if (k is! String || v is! int) {
        throw const FormatException('state_counts entries must be ints');
      }
      stateCounts[k] = v;
    }
    return UploadBatch(
      batchUuid: jsonString(m, 'batch_uuid'),
      label: jsonStringOrNull(m, 'label'),
      createdAt: jsonInt(m, 'created_at'),
      updatedAt: jsonInt(m, 'updated_at'),
      itemCount: jsonInt(m, 'item_count'),
      stateCounts: stateCounts,
      itemsPath: jsonString(m, 'items_path'),
    );
  }

  final String batchUuid;
  final String? label;
  final int createdAt;
  final int updatedAt;
  final int itemCount;

  /// Per raw state, non-zero counts only (as the server sends them).
  final Map<String, int> stateCounts;
  final String itemsPath;

  Map<String, dynamic> toJson() => {
    'batch_uuid': batchUuid,
    'label': label,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'item_count': itemCount,
    'state_counts': stateCounts,
    'items_path': itemsPath,
  };
}

/// `GET /tracks/uploads?after=&limit=`.
class UploadBatchPage {
  const UploadBatchPage({required this.batches, required this.nextAfter});
  factory UploadBatchPage.fromJson(Object? json) {
    final m = jsonObject(json, 'batch page');
    return UploadBatchPage(
      batches: [for (final b in jsonList(m, 'batches')) UploadBatch.fromJson(b)],
      nextAfter: jsonStringOrNull(m, 'next_after'),
    );
  }
  final List<UploadBatch> batches;

  /// Opaque cursor; null on the last page.
  final String? nextAfter;
}

/// `GET /tracks/uploads/{batch}/items?after=&limit=`.
class UploadItemPage {
  const UploadItemPage({required this.items, required this.nextAfter});
  factory UploadItemPage.fromJson(Object? json) {
    final m = jsonObject(json, 'item page');
    return UploadItemPage(
      items: [for (final i in jsonList(m, 'items')) UploadItem.fromJson(i)],
      nextAfter: jsonStringOrNull(m, 'next_after'),
    );
  }
  final List<UploadItem> items;
  final String? nextAfter;
}

/// The allocation answer (201 new, 200 exact replay): `{batch, items, limits}`.
class AllocationResult {
  const AllocationResult({
    required this.batch,
    required this.items,
    required this.limits,
  });
  factory AllocationResult.fromJson(Object? json) {
    final m = jsonObject(json, 'allocation result');
    final limits = m['limits'];
    if (limits is! Map) throw const FormatException('limits must be an object');
    return AllocationResult(
      batch: UploadBatch.fromJson(m['batch']),
      items: [for (final i in jsonList(m, 'items')) UploadItem.fromJson(i)],
      limits: UploadLimits.fromJson(limits),
    );
  }
  final UploadBatch batch;
  final List<UploadItem> items;
  final UploadLimits limits;
}

/// One file of an allocation (`{item_uuid, filename, byte_length, sha256}`).
/// [filename] is the display name; a local path is never sent.
class AllocationItem {
  const AllocationItem({
    required this.itemUuid,
    required this.filename,
    required this.byteLength,
    required this.sha256,
  });
  final String itemUuid;
  final String filename;
  final int byteLength;
  final String sha256;
}

/// `POST /tracks/uploads` body. A null label is left out (the server treats
/// absent and null alike).
class AllocationRequest {
  const AllocationRequest({
    required this.batchUuid,
    this.label,
    required this.items,
  });
  final String batchUuid;
  final String? label;
  final List<AllocationItem> items;

  Map<String, dynamic> toJson() => {
    'batch_uuid': batchUuid,
    if (label != null) 'label': label,
    'items': [
      for (final i in items)
        {
          'item_uuid': i.itemUuid,
          'filename': i.filename,
          'byte_length': i.byteLength,
          'sha256': i.sha256,
        },
    ],
  };

  /// The body frozen by `DurableSubmission.prepare` (SC-14): `jsonEncode` of
  /// [toJson], stable for the same request.
  String toFrozenJson() => jsonEncode(toJson());
}

/// A duplicate-check layer (SC-25).
enum DuplicateLayer { exact, fingerprint }

/// How much of the owner's library one layer could compare (SC-25
/// `LayerCoverage`). Every field null = unknown.
class LayerCoverage {
  const LayerCoverage({
    this.subjectState,
    this.libraryPending,
    this.libraryFailed,
    this.libraryNotComparable,
  });
  final String? subjectState;
  final int? libraryPending;
  final int? libraryFailed;
  final int? libraryNotComparable;

  /// Unknown (all null) when the layer is missing or not an object; a count
  /// that is missing or not an int is unknown, never 0.
  factory LayerCoverage.fromJson(Object? json) {
    if (json is! Map) return const LayerCoverage();
    final m = Map<String, dynamic>.from(json);
    int? count(String key) {
      final v = m[key];
      return v is int ? v : null;
    }

    final state = m['subject_state'];
    return LayerCoverage(
      subjectState: state is String ? state : null,
      libraryPending: count('library_pending'),
      libraryFailed: count('library_failed'),
      libraryNotComparable: count('library_not_comparable'),
    );
  }

  Map<String, dynamic> toJson() => {
    'subject_state': subjectState,
    'library_pending': libraryPending,
    'library_failed': libraryFailed,
    'library_not_comparable': libraryNotComparable,
  };

  /// The subject is `current` and nothing in the library is pending or
  /// failed (both known zero). Not-comparable tracks don't block it.
  bool get isComplete =>
      subjectState == 'current' && libraryPending == 0 && libraryFailed == 0;
}

/// Who a match points at.
sealed class DuplicateSubject {
  const DuplicateSubject();
}

/// A library track, with its summary resolved when the server read the item
/// ([available] false: the track is gone; the summary is then absent).
final class LibraryTrackSubject extends DuplicateSubject {
  const LibraryTrackSubject({
    required this.trackUuid,
    this.available,
    this.title,
    this.artist,
    this.album,
    this.codec,
    this.bitrateKbps,
    this.sampleRateHz,
    this.durationS,
  });
  final String trackUuid;
  final bool? available;
  final String? title;
  final String? artist;
  final String? album;
  final String? codec;
  final double? bitrateKbps;
  final int? sampleRateHz;
  final double? durationS;
}

/// Another staged upload item of the same user.
final class StagedItemSubject extends DuplicateSubject {
  const StagedItemSubject({
    required this.itemUuid,
    this.available,
    this.filename,
    this.batchUuid,
    this.batchCreatedAt,
  });
  final String itemUuid;
  final bool? available;
  final String? filename;
  final String? batchUuid;

  /// Unix seconds.
  final int? batchCreatedAt;
}

/// A subject kind this client doesn't know; kept so a match is never lost.
/// [raw] is the whole match as received.
final class UnknownDuplicateSubject extends DuplicateSubject {
  const UnknownDuplicateSubject(this.kind, this.raw);
  final String kind;
  final Map<String, dynamic> raw;
}

/// One match (`{subject_kind, track_uuid?, item_uuid?, kind, band, score?,
/// available, track?, staged_item?}`).
class DuplicateMatch {
  const DuplicateMatch({
    required this.kind,
    required this.band,
    required this.score,
    required this.subject,
  });

  /// A [FormatException] when the match is malformed.
  factory DuplicateMatch.fromJson(Object? json) {
    // A copy: an unknown subject keeps it as its raw match.
    final m = Map<String, dynamic>.from(jsonObject(json, 'match'));
    final subjectKind = jsonString(m, 'subject_kind');
    final kind = jsonString(m, 'kind');
    final band = jsonString(m, 'band');
    final score = jsonDoubleOrNull(m, 'score');
    final DuplicateSubject subject;
    switch (subjectKind) {
      case 'library_track':
        final trackJson = m['track'];
        final track = trackJson == null ? null : jsonObject(trackJson, 'track');
        subject = LibraryTrackSubject(
          trackUuid: jsonString(m, 'track_uuid'),
          available: jsonBoolOrNull(m, 'available'),
          title: track == null ? null : jsonStringOrNull(track, 'title'),
          artist: track == null ? null : jsonStringOrNull(track, 'artist'),
          album: track == null ? null : jsonStringOrNull(track, 'album'),
          codec: track == null ? null : jsonStringOrNull(track, 'codec'),
          bitrateKbps: track == null ? null : jsonDoubleOrNull(track, 'bitrate_kbps'),
          sampleRateHz: track == null ? null : jsonIntOrNull(track, 'sample_rate_hz'),
          durationS: track == null ? null : jsonDoubleOrNull(track, 'duration_s'),
        );
      case 'staged_item':
        final stagedJson = m['staged_item'];
        final staged = stagedJson == null ? null : jsonObject(stagedJson, 'staged_item');
        subject = StagedItemSubject(
          itemUuid: jsonString(m, 'item_uuid'),
          available: jsonBoolOrNull(m, 'available'),
          filename: staged == null ? null : jsonStringOrNull(staged, 'filename'),
          batchUuid: staged == null ? null : jsonStringOrNull(staged, 'batch_uuid'),
          batchCreatedAt:
              staged == null ? null : jsonIntOrNull(staged, 'batch_created_at'),
        );
      default:
        subject = UnknownDuplicateSubject(subjectKind, m);
    }
    return DuplicateMatch(kind: kind, band: band, score: score, subject: subject);
  }

  Map<String, dynamic> toJson() {
    final s = subject;
    switch (s) {
      case LibraryTrackSubject():
        return {
          'subject_kind': 'library_track',
          'track_uuid': s.trackUuid,
          'item_uuid': null,
          'kind': kind,
          'band': band,
          'score': score,
          'available': s.available,
          'track': s.available == false
              ? null
              : {
                  'title': s.title,
                  'artist': s.artist,
                  'album': s.album,
                  'codec': s.codec,
                  'bitrate_kbps': s.bitrateKbps,
                  'sample_rate_hz': s.sampleRateHz,
                  'duration_s': s.durationS,
                },
          'staged_item': null,
        };
      case StagedItemSubject():
        return {
          'subject_kind': 'staged_item',
          'track_uuid': null,
          'item_uuid': s.itemUuid,
          'kind': kind,
          'band': band,
          'score': score,
          'available': s.available,
          'track': null,
          'staged_item': {
            'filename': s.filename,
            'batch_uuid': s.batchUuid,
            'batch_created_at': s.batchCreatedAt,
          },
        };
      case UnknownDuplicateSubject():
        return s.raw;
    }
  }

  /// `exact` or `fingerprint` (raw).
  final String kind;

  /// `exact`, `strong` or `possible` (raw).
  final String band;

  /// Null for exact matches.
  final double? score;
  final DuplicateSubject subject;

  bool get isExact => kind == 'exact';
}

/// An item's `duplicate_check` (SC-25 `DuplicateReport`). The match list is
/// complete (uncapped). A check that can't be read ([isReadable] false) is
/// never "none found" and never makes the item unreadable.
class DuplicateCheck {
  const DuplicateCheck({
    required this.version,
    required this.status,
    required this.exact,
    required this.fingerprint,
    required this.matches,
    this.reportedNoDuplicates,
    this.isReadable = true,
  });

  /// Never throws: malformed input is an unreadable check.
  factory DuplicateCheck.fromJson(Object? json) {
    try {
      final m = jsonObject(json, 'duplicate check');
      final version = m['version'];
      final status = m['status'];
      final reported = m['no_duplicates_found'];
      return DuplicateCheck(
        version: version is int ? version : null,
        status: status is String ? status : null,
        reportedNoDuplicates: reported is bool ? reported : null,
        exact: LayerCoverage.fromJson(m['exact']),
        fingerprint: LayerCoverage.fromJson(m['fingerprint']),
        matches: [for (final x in jsonList(m, 'matches')) DuplicateMatch.fromJson(x)],
      );
    } on FormatException {
      return const DuplicateCheck.unreadable();
    }
  }

  const DuplicateCheck.unreadable()
    : version = null,
      status = null,
      reportedNoDuplicates = null,
      exact = const LayerCoverage(),
      fingerprint = const LayerCoverage(),
      matches = const [],
      isReadable = false;

  final int? version;

  /// `complete` or `failed` (raw; anything else is not "complete").
  final String? status;

  /// What the server said; never used for the decision.
  final bool? reportedNoDuplicates;
  final LayerCoverage exact;
  final LayerCoverage fingerprint;
  final List<DuplicateMatch> matches;
  final bool isReadable;

  /// The check was read and ran to completion (`status` is `complete`). An
  /// unreadable or failed check is never "no duplicates found".
  bool get ranToCompletion => isReadable && status == 'complete';

  /// The SC-25 rule: "no duplicates found" may be said for [layers] only
  /// for a readable, complete check with no matches and every named layer
  /// complete.
  bool noDuplicatesFound({required Set<DuplicateLayer> layers}) {
    if (layers.isEmpty) {
      throw ArgumentError.value(layers, 'layers', 'must name a layer');
    }
    if (!ranToCompletion || matches.isNotEmpty) return false;
    return layers.every(
      (l) => (l == DuplicateLayer.exact ? exact : fingerprint).isComplete,
    );
  }

  Map<String, dynamic> toJson() => isReadable
      ? {
          'version': version,
          'status': status,
          'no_duplicates_found': reportedNoDuplicates,
          'exact': exact.toJson(),
          'fingerprint': fingerprint.toJson(),
          'matches': [for (final x in matches) x.toJson()],
        }
      : {'version': null, 'status': null, 'matches': null};
}

/// The tags read from the file (detected metadata v1). Every tag may be
/// null (unknown).
class DetectedTags {
  const DetectedTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.date,
    this.year,
    this.genre,
    this.trackNumber,
    this.discNumber,
  });

  /// An absent or null `tags` object is all-null tags.
  factory DetectedTags.fromJson(Object? json) {
    if (json == null) return const DetectedTags();
    final m = jsonObject(json, 'tags');
    return DetectedTags(
      title: jsonStringOrNull(m, 'title'),
      artist: jsonStringOrNull(m, 'artist'),
      album: jsonStringOrNull(m, 'album'),
      albumArtist: jsonStringOrNull(m, 'album_artist'),
      date: jsonStringOrNull(m, 'date'),
      year: jsonIntOrNull(m, 'year'),
      genre: jsonStringOrNull(m, 'genre'),
      trackNumber: jsonIntOrNull(m, 'track_number'),
      discNumber: jsonIntOrNull(m, 'disc_number'),
    );
  }

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? date;
  final int? year;
  final String? genre;
  final int? trackNumber;
  final int? discNumber;

  /// The value of an editable field key (`title`, `artist`, `album`,
  /// `album_artist`, `date`, `year`, `genre`, `track_number`,
  /// `disc_number`); null for any other key.
  Object? valueOf(String key) => switch (key) {
    'title' => title,
    'artist' => artist,
    'album' => album,
    'album_artist' => albumArtist,
    'date' => date,
    'year' => year,
    'genre' => genre,
    'track_number' => trackNumber,
    'disc_number' => discNumber,
    _ => null,
  };

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'album_artist': albumArtist,
    'date': date,
    'year': year,
    'genre': genre,
    'track_number': trackNumber,
    'disc_number': discNumber,
  };
}

/// An item's `detected_metadata` (v1). Audio facts null = unknown, never 0.
class DetectedMetadata {
  const DetectedMetadata({
    this.container,
    this.codec,
    this.mime,
    this.durationS,
    this.bitrateKbps,
    this.sampleRateHz,
    this.channels,
    this.hasAlbumArt,
    this.tags = const DetectedTags(),
  });

  factory DetectedMetadata.fromJson(Object? json) {
    final m = jsonObject(json, 'detected metadata');
    return DetectedMetadata(
      container: jsonStringOrNull(m, 'container'),
      codec: jsonStringOrNull(m, 'codec'),
      mime: jsonStringOrNull(m, 'mime'),
      durationS: jsonDoubleOrNull(m, 'duration_s'),
      bitrateKbps: jsonDoubleOrNull(m, 'bitrate_kbps'),
      sampleRateHz: jsonIntOrNull(m, 'sample_rate_hz'),
      channels: jsonIntOrNull(m, 'channels'),
      hasAlbumArt: jsonBoolOrNull(m, 'has_album_art'),
      tags: DetectedTags.fromJson(m['tags']),
    );
  }

  final String? container;
  final String? codec;
  final String? mime;
  final double? durationS;
  final double? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final bool? hasAlbumArt;
  final DetectedTags tags;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'container': container,
    'codec': codec,
    'mime': mime,
    'duration_s': durationS,
    'bitrate_kbps': bitrateKbps,
    'sample_rate_hz': sampleRateHz,
    'channels': channels,
    'has_album_art': hasAlbumArt,
    'tags': tags.toJson(),
  };
}

/// The duplicates the user chose to import anyway (spec §4
/// `acknowledged_duplicates`).
class AcknowledgedDuplicates {
  const AcknowledgedDuplicates({
    this.libraryTracks = const {},
    this.stagedItems = const {},
  });
  static const none = AcknowledgedDuplicates();
  final Set<String> libraryTracks;
  final Set<String> stagedItems;
  bool get isEmpty => libraryTracks.isEmpty && stagedItems.isEmpty;

  /// Sorted lists, so the same set always encodes to the same text.
  Map<String, dynamic> toJson() => {
    'library_tracks': libraryTracks.toList()..sort(),
    'staged_items': stagedItems.toList()..sort(),
  };
}

/// `POST .../commit` body, without the operation id (added by the durable
/// submission layer). Canonical: edit keys are sorted and the ack sets are
/// sorted, so the same request always freezes to the same text.
class CommitBody {
  const CommitBody({
    required this.baseReviewVersion,
    required this.edits,
    required this.writeTags,
    required this.acknowledged,
  });
  final int baseReviewVersion;

  /// Field key to new value; an explicit null (clear the field) is kept.
  final Map<String, Object?> edits;
  final bool writeTags;
  final AcknowledgedDuplicates acknowledged;

  Map<String, dynamic> toJson() {
    final keys = edits.keys.toList()..sort();
    return {
      'base_review_version': baseReviewVersion,
      'edits': {for (final k in keys) k: edits[k]},
      'write_tags': writeTags,
      'acknowledged_duplicates': acknowledged.toJson(),
    };
  }
}

/// `POST .../resolve-duplicate` body, without the operation id.
class ResolveDuplicateBody {
  const ResolveDuplicateBody({
    required this.expectedReviewVersion,
    required this.existingTrackUuid,
  });
  final int expectedReviewVersion;
  final String existingTrackUuid;
  Map<String, dynamic> toJson() => {
    'expected_review_version': expectedReviewVersion,
    'existing_track_uuid': existingTrackUuid,
  };
}
