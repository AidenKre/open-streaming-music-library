import 'package:frontend/models/dto/track_metadata_dto.dart';

class ClientTrackDto {
  final String uuidId;
  final TrackMetadataDto metadata;
  final int createdAt;
  final int lastUpdated;

  const ClientTrackDto({
    required this.uuidId,
    required this.metadata,
    required this.createdAt,
    required this.lastUpdated,
  });

  factory ClientTrackDto.fromJson(Map<String, dynamic> json) {
    return ClientTrackDto(
      uuidId: json['uuid_id'] as String,
      metadata: TrackMetadataDto.fromJson(
        json['metadata'] as Map<String, dynamic>,
      ),
      createdAt: (json['created_at'] as num).toInt(),
      lastUpdated: (json['last_updated'] as num).toInt(),
    );
  }
}