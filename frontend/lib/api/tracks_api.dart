import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/get_changes_response_dto.dart';
import 'package:frontend/models/dto/get_tracks_response_dto.dart';

class TracksApi {
  final ApiClient _apiClient = ApiClient.instance;

  /// Fetches one page of the revision-based change stream for incremental
  /// sync. Pass the last applied revision as [afterRevision] (0 = full
  /// resync); page until the response's nextCursor is null.
  Future<GetChangesResponseDto> getChangesPage({
    int afterRevision = 0,
    int limit = 500,
  }) async {
    final query = <String, String>{
      'after_revision': afterRevision.toString(),
      'limit': limit.toString(),
    };

    final json = await _apiClient.getJson(['changes'], query: query);
    return GetChangesResponseDto.fromJson(json);
  }

  /// Fetches one page of tracks in display order for browsing.
  /// Returns the parsed response with data + nextCursor.
  Future<GetTracksResponseDto> getTracksPage({
    String? cursor,
    int? artistId,
    int? albumId,
    int limit = 500,
  }) async {
    final query = <String, String>{
      'limit': limit.toString(),
      if (cursor != null) 'cursor': cursor,
      if (artistId != null) 'artist_id': artistId.toString(),
      if (albumId != null) 'album_id': albumId.toString(),
    };

    final json = await _apiClient.getJson(['tracks'], query: query);
    return GetTracksResponseDto.fromJson(json);
  }
}
