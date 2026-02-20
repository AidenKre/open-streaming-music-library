import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/pagination.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/dto/get_tracks_response_dto.dart';

class TracksApi extends IPaginatingListApi {
  final ApiClient _apiClient = ApiClient.instance;
  final String _endpoint = 'tracks';
  String? _nextCursor;
  List<ClientTrackDto> _tracks = [];

  @override
  Future<List<dynamic>> getInitialItems() async {
    final Map<String, String> query = {"limit": "100"};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
    ], query: query);

    final response = GetTracksResponseDto.fromJson(jsonObj);
    _tracks = response.data;
    _nextCursor = response.nextCursor;

    return _tracks;
  }

  @override
  Future<List<dynamic>> getNextItems() async {
    if (_nextCursor == null) return [];
    final Map<String, String> query = {"cursor": _nextCursor as String};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
    ], query: query);

    final response = GetTracksResponseDto.fromJson(jsonObj);
    _nextCursor = response.nextCursor;

    final existingIds = _tracks.map((t) => t.uuidId).toSet();
    final newTracks = response.data
        .where((t) => !existingIds.contains(t.uuidId))
        .toList();

    _tracks.addAll(newTracks);
    return newTracks;
  }

  @override
  List<dynamic> getGottenItems() {
    return _tracks;
  }

  List<ClientTrackDto> convertToDtos(List<Map<String, dynamic>> trackJsonList) {
    return trackJsonList.map(ClientTrackDto.fromJson).toList();
  }
}
