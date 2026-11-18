import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/dto/get_changes_response_dto.dart';
import 'package:frontend/models/instance_stamp.dart';

class TracksApi {
  TracksApi({required ApiClient api}) : _apiClient = api;

  final ApiClient _apiClient;

  /// Fetches the authoritative current state of a single track. Used to
  /// reconcile one track to server truth (e.g. conflict "take server") without
  /// a watermark-driven `/changes` pull. Surfaces 404/410 as `ApiException` so
  /// the caller can treat a gone track as a local delete.
  Future<ClientTrackDto> getTrack(String uuidId) async {
    final json = await _apiClient.getJson(['tracks', uuidId], retry: false);
    return ClientTrackDto.fromJson(json);
  }

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

    final response = await _apiClient.getJsonResponse(['changes'], query: query);
    return GetChangesResponseDto.fromJson(
      response.body,
      servedBy: instanceStampFrom(response.headers),
    );
  }

  /// Applies a metadata edit. [body] carries the touched fields plus
  /// `base_revision` and `write_mode`. Returns the parsed response
  /// (`uuid_id`, `revision`, `master_written`). `retry: true` retries only
  /// transport errors and the retryable statuses (5xx gateway errors, 408,
  /// 429); 409 (conflict) / 404 / 410 surface as `ApiException` for the
  /// caller.
  Future<Map<String, dynamic>> patchTrack(
    String uuidId,
    Map<String, dynamic> body,
  ) {
    return _apiClient.patchJson(['tracks', uuidId], body: body, retry: true);
  }
}
