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

  /// Applies a metadata edit. [body] carries the touched fields plus
  /// `base_revision` and `write_mode`. Returns the parsed response
  /// (`uuid_id`, `revision`, `master_written`). `retry: true` is transport-only;
  /// 409 (conflict) / 404 / 410 surface as `ApiException` for the caller.
  Future<Map<String, dynamic>> patchTrack(
    String uuidId,
    Map<String, dynamic> body,
  ) {
    return _apiClient.patchJson(['tracks', uuidId], body: body, retry: true);
  }
}
