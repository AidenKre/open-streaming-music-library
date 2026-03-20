import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/get_tracks_response_dto.dart';

class TracksApi {
  final ApiClient _apiClient = ApiClient.instance;

  /// Fetches one page of tracks from the backend.
  /// Returns the parsed response with data + nextCursor.
  Future<GetTracksResponseDto> getTracksPage({
    String? cursor,
    int? newerThan,
    int? olderThan,
    int? artistId,
    int? albumId,
    int limit = 500,
  }) async {
    final query = <String, String>{
      'limit': limit.toString(),
      if (cursor != null) 'cursor': cursor,
      if (newerThan != null) 'newer_than': newerThan.toString(),
      if (olderThan != null) 'older_than': olderThan.toString(),
      if (artistId != null) 'artist_id': artistId.toString(),
      if (albumId != null) 'album_id': albumId.toString(),
    };

    final json = await _apiClient.getJson(['tracks'], query: query);
    return GetTracksResponseDto.fromJson(json);
  }
}
