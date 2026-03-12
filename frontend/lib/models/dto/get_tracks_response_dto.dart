import 'package:frontend/models/dto/client_track_dto.dart';

class GetTracksResponseDto {
  final List<ClientTrackDto> data;
  final String? nextCursor;

  const GetTracksResponseDto({required this.data, this.nextCursor});

  factory GetTracksResponseDto.fromJson(Map<String, dynamic> json) {
    return GetTracksResponseDto(
      data: (json['data'] as List<dynamic>)
          .map((e) => ClientTrackDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['nextCursor'] as String?,
    );
  }
}
