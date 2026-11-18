import 'package:frontend/models/dto/json_fields.dart';
import 'package:frontend/models/dto/track_metadata_dto.dart';

class ClientTrackDto {
  final String uuidId;
  final TrackMetadataDto metadata;
  final int createdAt;
  final int lastUpdated;

  /// Monotonic per-track revision, sourced from the track payload (not the
  /// `ChangeEntryDto` envelope, which is the sync watermark). The server
  /// always sends a concrete int; it becomes the conflict-detection base for
  /// edits (Option A).
  final int revision;

  const ClientTrackDto({
    required this.uuidId,
    required this.metadata,
    required this.createdAt,
    required this.lastUpdated,
    required this.revision,
  });

  /// Typed reads: a missing or malformed field is a [FormatException].
  factory ClientTrackDto.fromJson(Map<String, dynamic> json) {
    return ClientTrackDto(
      uuidId: jsonString(json, 'uuid_id'),
      metadata: TrackMetadataDto.fromJson(
        jsonObject(json['metadata'], 'metadata'),
      ),
      createdAt: jsonWholeInt(json, 'created_at'),
      lastUpdated: jsonWholeInt(json, 'last_updated'),
      revision: jsonWholeInt(json, 'revision'),
    );
  }
}