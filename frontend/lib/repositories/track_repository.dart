import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';

sealed class TrackCursor {
  const TrackCursor();
}

class AllTracksCursor extends TrackCursor {
  final int offset;
  const AllTracksCursor(this.offset);
}

class AlbumTracksCursor extends TrackCursor {
  final String artist;
  final String album;
  final int offset;
  const AlbumTracksCursor({
    required this.artist,
    required this.album,
    required this.offset,
  });
}

class TrackPage {
  final List<TrackUI> items;
  final TrackCursor? nextCursor;
  const TrackPage({required this.items, this.nextCursor});
}

class TrackRepository {
  static const int pageSize = 100;
  final AppDatabase _db;

  TrackRepository(this._db);

  Stream<void> get tracksChanged =>
      _db.select(_db.tracks).watch().map<void>((_) {});

  Future<TrackPage> getAllTracks({AllTracksCursor? cursor}) async {
    final offset = cursor?.offset ?? 0;
    final rows = await _db.getTrackPage(limit: pageSize, offset: offset);
    final items = rows
        .map(
          (row) => TrackUI.fromDrift(
            row.readTable(_db.tracks),
            row.readTable(_db.trackmetadata),
          ),
        )
        .toList();
    final nextCursor = items.length == pageSize
        ? AllTracksCursor(offset + pageSize)
        : null;
    return TrackPage(items: items, nextCursor: nextCursor);
  }

  Future<TrackPage> getAlbumTracks({
    required String artist,
    required String album,
    AlbumTracksCursor? cursor,
  }) async {
    final offset = cursor?.offset ?? 0;
    final rows = await _db.getAlbumTrackPage(
      artist: artist,
      album: album,
      limit: pageSize,
      offset: offset,
    );
    final items = rows
        .map(
          (row) => TrackUI.fromDrift(
            row.readTable(_db.tracks),
            row.readTable(_db.trackmetadata),
          ),
        )
        .toList();
    final nextCursor = items.length == pageSize
        ? AlbumTracksCursor(
            artist: artist,
            album: album,
            offset: offset + pageSize,
          )
        : null;
    return TrackPage(items: items, nextCursor: nextCursor);
  }
}
