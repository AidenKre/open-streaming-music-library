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

  factory ClientTrackDto.fromJson(Map<String, dynamic> json) {
    return ClientTrackDto(
      uuidId: json['uuid_id'] as String,
      metadata: TrackMetadataDto.fromJson(
        json['metadata'] as Map<String, dynamic>,
      ),
      createdAt: (json['created_at'] as num).toInt(),
      lastUpdated: (json['last_updated'] as num).toInt(),
      revision: (json['revision'] as num).toInt(),
    );
  }
}