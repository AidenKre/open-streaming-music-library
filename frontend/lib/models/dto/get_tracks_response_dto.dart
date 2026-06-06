import 'package:frontend/models/dto/client_track_dto.dart';

class GetTracksResponseDto {
  final List<ClientTrackDto> data;
  final String? nextCursor;
  final List<String> deletedUuids;

  const GetTracksResponseDto({
    required this.data,
    this.nextCursor,
    this.deletedUuids = const [],
  });

  factory GetTracksResponseDto.fromJson(Map<String, dynamic> json) {
    final rawDeleted = json['deleted_uuids'] as List<dynamic>?;
    return GetTracksResponseDto(
      data: (json['data'] as List<dynamic>)
          .map((e) => ClientTrackDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['nextCursor'] as String?,
      deletedUuids:
          rawDeleted == null ? const [] : rawDeleted.cast<String>().toList(),
    );
  }
}
