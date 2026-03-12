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
  final double duration;
  final double bitrateKbps;
  final int sampleRateHz;
  final int channels;
  final bool hasAlbumArt;

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
  });

  factory TrackMetadataDto.fromJson(Map<String, dynamic> json) {
    return TrackMetadataDto(
      title: json['title'] as String?,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      albumArtist: json['album_artist'] as String?,
      year: (json['year'] as num?)?.toInt(),
      date: json['date'] as String?,
      genre: json['genre'] as String?,
      trackNumber: (json['track_number'] as num?)?.toInt(),
      discNumber: (json['disc_number'] as num?)?.toInt(),
      codec: json['codec'] as String?,
      duration: (json['duration'] as num).toDouble(),
      bitrateKbps: (json['bitrate_kbps'] as num).toDouble(),
      sampleRateHz: (json['sample_rate_hz'] as num).toInt(),
      channels: (json['channels'] as num).toInt(),
      hasAlbumArt: json['has_album_art'] as bool? ?? false,
    );
  }
}