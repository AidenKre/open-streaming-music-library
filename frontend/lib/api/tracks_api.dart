import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/pagination.dart';
import 'package:frontend/database/database.dart';

class TracksApi extends IPaginatingListApi {
  final ApiClient _apiClient = ApiClient.instance;
  final String _endpoint = 'tracks';
  String? _nextCursor;
  List<TracksCompanion> _tracks = [];

  @override
  Future<List<dynamic>> getInitialItems() async {
    final Map<String, String> query = {"limit": "100"};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
    ], query: query);

    List<Map<String, dynamic>> jsonTracks = List<Map<String, dynamic>>.from(
      jsonObj["data"],
    );
    _tracks = convertToTrackCompanion(jsonTracks);
    _nextCursor = jsonObj["nextCursor"] as String?;

    return _tracks;
  }

  @override
  Future<List<dynamic>> getNextItems() async {
    if (_nextCursor == null) return [];
    final Map<String, String> query = {"cursor": _nextCursor as String};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
    ], query: query);
    List<Map<String, dynamic>> jsonTracks = List<Map<String, dynamic>>.from(
      jsonObj["data"],
    );
    _nextCursor = jsonObj["nextCursor"] as String?;

    final existingTracks = _tracks.map((track) => track.uuidId).toSet();
    final newTracks = convertToTrackCompanion(
      jsonTracks,
    ).where((item) => !existingTracks.contains(item.uuidId)).toList();

    _tracks.addAll(newTracks);
    return newTracks;
  }

  @override
  List<dynamic> getGottenItems() {
    return _tracks;
  }

  List<TracksCompanion> convertToTrackCompanion(
    List<Map<String, dynamic>> trackJsonList,
  ) {
    List<TracksCompanion> trackCompanions = [];
    for (Map<String, dynamic> trackJson in trackJsonList) {
      trackCompanions.add(tracksCompanionFromJson(trackJson));
    }
    return trackCompanions;
  }
}
