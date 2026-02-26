import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';

sealed class TrackCursor {
  const TrackCursor();
}

class AllTracksCursor extends TrackCursor {
  final String? artist;
  final String? album;
  final int? trackNumber;
  final String uuidId;
  const AllTracksCursor({
    required this.artist,
    required this.album,
    required this.trackNumber,
    required this.uuidId,
  });
}

class AlbumTracksCursor extends TrackCursor {
  final int? trackNumber;
  final String uuidId;
  const AlbumTracksCursor({
    required this.trackNumber,
    required this.uuidId,
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
    final rows = await _db.getTrackPage(
      limit: pageSize,
      cursorArtist: cursor?.artist,
      cursorAlbum: cursor?.album,
      cursorTrackNumber: cursor?.trackNumber,
      cursorUuidId: cursor?.uuidId,
    );
    final items = rows.map(_trackUIFromRow).toList();
    final TrackCursor? nextCursor;
    if (items.length == pageSize) {
      final last = items.last;
      nextCursor = AllTracksCursor(
        artist: last.artist,
        album: last.album,
        trackNumber: last.trackNumber,
        uuidId: last.uuidId,
      );
    } else {
      nextCursor = null;
    }
    return TrackPage(items: items, nextCursor: nextCursor);
  }

  Future<TrackPage> getAlbumTracks({
    required String artist,
    required String album,
    AlbumTracksCursor? cursor,
  }) async {
    final rows = await _db.getAlbumTrackPage(
      artist: artist,
      album: album,
      limit: pageSize,
      cursorTrackNumber: cursor?.trackNumber,
      cursorUuidId: cursor?.uuidId,
    );
    final items = rows.map(_trackUIFromRow).toList();
    final TrackCursor? nextCursor;
    if (items.length == pageSize) {
      final last = items.last;
      nextCursor = AlbumTracksCursor(
        trackNumber: last.trackNumber,
        uuidId: last.uuidId,
      );
    } else {
      nextCursor = null;
    }
    return TrackPage(items: items, nextCursor: nextCursor);
  }

  static TrackUI _trackUIFromRow(QueryRow row) {
    return TrackUI(
      uuidId: row.read<String>('uuid_id'),
      filePath: row.readNullable<String>('file_path'),
      createdAt: row.read<int>('created_at'),
      lastUpdated: row.read<int>('last_updated'),
      title: row.readNullable<String>('title'),
      artist: row.readNullable<String>('artist'),
      album: row.readNullable<String>('album'),
      albumArtist: row.readNullable<String>('album_artist'),
      year: row.readNullable<int>('year'),
      date: row.readNullable<String>('date'),
      genre: row.readNullable<String>('genre'),
      trackNumber: row.readNullable<int>('track_number'),
      discNumber: row.readNullable<int>('disc_number'),
      codec: row.readNullable<String>('codec'),
      duration: row.read<double>('duration'),
      bitrateKbps: row.read<double>('bitrate_kbps'),
      sampleRateHz: row.read<int>('sample_rate_hz'),
      channels: row.read<int>('channels'),
      hasAlbumArt: row.read<bool>('has_album_art'),
    );
  }
}
