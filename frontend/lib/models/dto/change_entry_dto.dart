import 'package:frontend/models/dto/client_track_dto.dart';

enum ChangeEntryType { upsert, delete }

/// One entry in the revision-based change stream. [track] is set for
/// upserts and null for deletes; [uuidId] identifies the row in both cases.
class ChangeEntryDto {
  final ChangeEntryType type;
  final int revision;
  final String uuidId;
  final ClientTrackDto? track;

  const ChangeEntryDto({
    required this.type,
    required this.revision,
    required this.uuidId,
    this.track,
  });

  bool get isUpsert => type == ChangeEntryType.upsert;

  factory ChangeEntryDto.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'];
    final rawTrack = json['track'];
    final type = switch (rawType) {
      'upsert' => ChangeEntryType.upsert,
      'delete' => ChangeEntryType.delete,
      _ => throw FormatException('Unknown change type: $rawType'),
    };

    ClientTrackDto? track;
    final uuidId = json['uuid_id'] as String;
    switch (type) {
      case ChangeEntryType.upsert:
        if (rawTrack is! Map) {
          throw const FormatException('Upsert change requires a track payload');
        }
        track = ClientTrackDto.fromJson(Map<String, dynamic>.from(rawTrack));
        if (track.uuidId != uuidId) {
          throw const FormatException(
            'Change uuid_id must match track uuid_id',
          );
        }
      case ChangeEntryType.delete:
        if (rawTrack != null) {
          throw const FormatException('Delete change must not include a track');
        }
        track = null;
    }

    return ChangeEntryDto(
      type: type,
      revision: (json['revision'] as num).toInt(),
      uuidId: uuidId,
      track: track,
    );
  }
}
