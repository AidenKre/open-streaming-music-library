import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/library_actions.dart';

/// Records every library action as `method scope[ extra]`, for widget tests
/// that override `libraryActionsProvider`.
class FakeLibraryActions implements LibraryActionControls {
  final calls = <String>[];

  static String describe(LibraryScope scope) => switch (scope) {
    AlbumScope(:final artistId, :final albumId) => 'album($artistId,$albumId)',
    ArtistScope(:final artistId) => 'artist($artistId)',
    TrackScope(:final track) => 'track(${track.uuidId})',
    TracksScope(:final tracks) =>
      'tracks(${tracks.map((t) => t.uuidId).join(',')})',
  };

  @override
  Future<void> playNext(LibraryScope scope) async =>
      calls.add('playNext ${describe(scope)}');

  @override
  Future<void> addToQueue(LibraryScope scope) async =>
      calls.add('addToQueue ${describe(scope)}');

  @override
  Future<void> playFromList(
    List<TrackUI> tracks,
    int startIndex, {
    required String source,
  }) async => calls.add(
    'playFromList ${tracks.map((t) => t.uuidId).join(',')} @$startIndex $source',
  );

  @override
  Future<void> playQuery(
    TrackUI track, {
    AlbumScope? album,
    required bool downloadedOnly,
  }) async => calls.add(
    'playQuery ${track.uuidId} ${album == null ? 'library' : describe(album)}'
    ' downloadedOnly=$downloadedOnly',
  );

  @override
  Future<void> download(LibraryScope scope) async =>
      calls.add('download ${describe(scope)}');

  @override
  Future<void> downloadAtQuality(LibraryScope scope, String quality) async =>
      calls.add('downloadAtQuality ${describe(scope)} $quality');

  @override
  Future<void> deleteDownloads(LibraryScope scope) async =>
      calls.add('deleteDownloads ${describe(scope)}');
}
