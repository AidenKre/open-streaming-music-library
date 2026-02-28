// Note that this class is not useful anymore, since we are offline first
// and just sync all metadata locally. No point querying the API for something
// we can just query the local db for.

import 'package:frontend/api/pagination.dart';
import 'package:frontend/api/api_client.dart';

class ArtistAlbumsApi extends IPaginatingListApi {
  final ApiClient _apiClient = ApiClient.instance;
  final String _endpoint = 'artists';
  String? _nextCursor;
  final String _artist;
  List<String> _albums = [];

  ArtistAlbumsApi(this._artist);

  @override
  Future<List<dynamic>> getInitialItems() async {
    final Map<String, String> query = {"limit": "100"};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
      _artist,
      "albums",
    ], query: query);

    _albums = List<String>.from(jsonObj["data"]);
    _nextCursor = jsonObj["nextCursor"] as String?;

    return _albums;
  }

  @override
  Future<List<dynamic>> getNextItems() async {
    if (_nextCursor == null) return [];
    final Map<String, String> query = {"cursor": _nextCursor as String};
    final Map<String, dynamic> jsonObj = await _apiClient.getJson([
      _endpoint,
      _artist,
      "albums",
    ], query: query);
    List<String> albumsFromJson = List<String>.from(jsonObj["data"]);
    _nextCursor = jsonObj["nextCursor"] as String?;

    final existingAlbums = _albums.toSet();
    final newAlbums = albumsFromJson
        .where((item) => !existingAlbums.contains(item))
        .toList();

    _albums.addAll(newAlbums);
    return newAlbums;
  }

  @override
  List<dynamic> getGottenItems() {
    return _albums;
  }
}
