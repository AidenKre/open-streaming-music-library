import 'package:frontend/models/dto/json_fields.dart';

class TrackMetadataDto {
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? year;
  final String? date;
  final String? genre;
  final int? trackNumber;
  final int? discNumber;
  final String? codec;
  // Audio properties: null when the server doesn't know them; 0 is a real
  // reading (SC-16l).
  final double? duration;
  final double? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final bool hasAlbumArt;
  final int? coverArtId;
  final int? artistId;
  final int? albumId;

  const TrackMetadataDto({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.year,
    this.date,
    this.genre,
    this.trackNumber,
    this.discNumber,
    this.codec,
    required this.duration,
    required this.bitrateKbps,
    required this.sampleRateHz,
    required this.channels,
    required this.hasAlbumArt,
    this.coverArtId,
    this.artistId,
    this.albumId,
  });

  /// Typed reads: a malformed field is a [FormatException]; a missing or null
  /// nullable field is unknown (null).
  factory TrackMetadataDto.fromJson(Map<String, dynamic> json) {
    return TrackMetadataDto(
      title: jsonStringOrNull(json, 'title'),
      artist: jsonStringOrNull(json, 'artist'),
      album: jsonStringOrNull(json, 'album'),
      albumArtist: jsonStringOrNull(json, 'album_artist'),
      year: jsonWholeIntOrNull(json, 'year'),
      date: jsonStringOrNull(json, 'date'),
      genre: jsonStringOrNull(json, 'genre'),
      trackNumber: jsonWholeIntOrNull(json, 'track_number'),
      discNumber: jsonWholeIntOrNull(json, 'disc_number'),
      codec: jsonStringOrNull(json, 'codec'),
      duration: _positiveOrUnknown(json['duration'])?.toDouble(),
      bitrateKbps: jsonDoubleOrNull(json, 'bitrate_kbps'),
      sampleRateHz: _positiveOrUnknown(json['sample_rate_hz'])?.toInt(),
      channels: _positiveOrUnknown(json['channels'])?.toInt(),
      hasAlbumArt: jsonBoolOrNull(json, 'has_album_art') ?? false,
      coverArtId: jsonWholeIntOrNull(json, 'cover_art_id'),
      artistId: jsonWholeIntOrNull(json, 'artist_id'),
      albumId: jsonWholeIntOrNull(json, 'album_id'),
    );
  }

  /// The server's value of the editable field [key] (a key of
  /// `defaultEditableTrackFields`); null for an unknown key.
  Object? editableValue(String key) => switch (key) {
        'title' => title,
        'artist' => artist,
        'album' => album,
        'album_artist' => albumArtist,
        'year' => year,
        'date' => date,
        'genre' => genre,
        'track_number' => trackNumber,
        'disc_number' => discNumber,
        _ => null,
      };

  /// Duration, sample rate and channels are never really 0: a pre-v10
  /// server sends 0 as its "unknown" stand-in (SC-16l), and its later
  /// upgrade bumps no revision, so the value would stay forever. Unknown is
  /// null (the unknown-vs-zero rule).
  static num? _positiveOrUnknown(Object? value) =>
      value is num && value > 0 ? value : null;
}
