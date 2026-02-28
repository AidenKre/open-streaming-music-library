// Note that this class is not useful anymore, since we are offline first
// and just sync all metadata locally. No point querying the API for something
// we can just query the local db for.

import 'package:frontend/api/pagination.dart';

import './api_client.dart';

class ArtistApi implements IPaginatingListApi {
  final ApiClient _apiClient = ApiClient.instance;
  final String _endpoint = 'artists';
  String? _nextCursor;
  List<String> _artists = [];

  @override
  Future<List<dynamic>> getInitialItems() async {
    final Map<String, String> query = {"limit": "100"};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
    ], query: query);

    _artists = List<String>.from(jsonObj["data"]);
    _nextCursor = jsonObj["nextCursor"] as String?;

    return _artists;
  }

  @override
  Future<List<dynamic>> getNextItems() async {
    if (_nextCursor == null) return [];
    final Map<String, String> query = {"cursor": _nextCursor as String};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
    ], query: query);
    List<String> artistsFromJson = List<String>.from(jsonObj["data"]);
    _nextCursor = jsonObj["nextCursor"] as String?;

    final existingArtists = _artists.toSet();
    final newArtists = artistsFromJson
        .where((item) => !existingArtists.contains(item))
        .toList();

    _artists.addAll(newArtists);
    return newArtists;
  }

  @override
  List<dynamic> getGottenItems() {
    return _artists;
  }
}
