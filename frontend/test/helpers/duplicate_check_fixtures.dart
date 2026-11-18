// Wire-shaped `duplicate_check` fixtures (7A.2c contract) for the duplicate
// UX tests (7B.2d). Every builder returns server JSON; items go through
// `UploadItem.fromJson`, so the tests read what the client really parses.
import 'package:frontend/models/dto/upload_dtos.dart';

Map<String, dynamic> coverageJson({
  String? subject = 'current',
  int? pending = 0,
  int? failed = 0,
  int? notComparable = 0,
}) => {
  'subject_state': subject,
  'library_pending': pending,
  'library_failed': failed,
  'library_not_comparable': notComparable,
};

/// A library-track match. [available] false (or null) comes with no summary,
/// as the server sends it.
Map<String, dynamic> libraryMatchJson(
  String trackUuid, {
  String kind = 'exact',
  String? band,
  double? score,
  bool? available = true,
  String? title,
  String? artist,
  String? album,
  String? codec = 'flac',
  double? bitrateKbps = 900,
  int? sampleRateHz = 44100,
  double? durationS = 252,
}) => {
  'subject_kind': 'library_track',
  'track_uuid': trackUuid,
  'item_uuid': null,
  'kind': kind,
  'band': band ?? (kind == 'exact' ? 'exact' : 'possible'),
  'score': score,
  'available': available,
  'track': available == true
      ? {
          'title': title ?? 'Title $trackUuid',
          'artist': artist ?? 'Artist $trackUuid',
          'album': album,
          'codec': codec,
          'bitrate_kbps': bitrateKbps,
          'sample_rate_hz': sampleRateHz,
          'duration_s': durationS,
        }
      : null,
  'staged_item': null,
};

/// A match against another staged item of the same user.
Map<String, dynamic> stagedMatchJson(
  String itemUuid, {
  String kind = 'exact',
  String? band,
  double? score,
  bool? available = true,
  String filename = 'other.flac',
  String batchUuid = 'b-1',
  int? batchCreatedAt = 1000,
}) => {
  'subject_kind': 'staged_item',
  'track_uuid': null,
  'item_uuid': itemUuid,
  'kind': kind,
  'band': band ?? (kind == 'exact' ? 'exact' : 'possible'),
  'score': score,
  'available': available,
  'track': null,
  'staged_item': available == true
      ? {
          'filename': filename,
          'batch_uuid': batchUuid,
          'batch_created_at': batchCreatedAt,
        }
      : null,
};

Map<String, dynamic> duplicateCheckJson({
  String status = 'complete',
  Map<String, dynamic>? exact,
  Map<String, dynamic>? fingerprint,
  List<Map<String, dynamic>> matches = const [],
}) {
  final e = exact ?? coverageJson();
  final f = fingerprint ?? coverageJson();
  return {
    'version': 1,
    'status': status,
    'no_duplicates_found': false,
    'exact': status == 'failed' ? null : e,
    'fingerprint': status == 'failed' ? null : f,
    'matches': matches,
  };
}

/// A review item of batch [batchUuid] with [check] as its `duplicate_check`
/// (null = not validated yet).
UploadItem reviewItem(
  String uuid, {
  String batchUuid = 'b-1',
  String state = 'review_ready',
  int version = 1,
  Map<String, dynamic>? check,
  List<Map<String, dynamic>>? conflicts,
  Map<String, dynamic>? detected,
  int index = 0,
}) => UploadItem.fromJson({
  'item_uuid': uuid,
  'batch_uuid': batchUuid,
  'parent_item_uuid': null,
  'filename': '$uuid.flac',
  'selection_index': index,
  'member_order_key': '',
  'state': state,
  'expected_bytes': 3,
  'expected_sha256': null,
  'received_bytes': 3,
  'review_version': version,
  'error': null,
  'created_at': 1,
  'updated_at': 1,
  'tag_write_supported': true,
  'duplicate_check': check,
  'conflict_matches': conflicts,
  'detected_metadata': detected,
});
