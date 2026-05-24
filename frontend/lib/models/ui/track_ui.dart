import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';

class TrackUI {
  final String uuidId;
  final String? filePath;
  final int createdAt;
  final int lastUpdated;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? artistId;
  final int? albumId;
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
  final int? coverArtId;
  // Bitrate of the file actually on disk. Null until a download completes.
  final int? downloadedBitrateKbps;
  // Size in bytes of the file on disk. Null until a download completes.
  final int? fileSizeBytes;
  // Quality preset that produced this download (e.g. 'original', '320').
  // Distinct from `downloadedBitrateKbps`, which is the actual on-disk
  // bitrate — for passthrough downloads the two can differ.
  final String? downloadedQuality;

  bool get isDownloaded => filePath != null;

  String get subtitle =>
      [artist ?? 'Unknown Artist', album].whereType<String>().join(' \u2014 ');

  const TrackUI({
    required this.uuidId,
    this.filePath,
    required this.createdAt,
    required this.lastUpdated,
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.artistId,
    this.albumId,
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
    this.downloadedBitrateKbps,
    this.fileSizeBytes,
    this.downloadedQuality,
  });

  static const Object _sentinel = Object();

  TrackUI copyWith({
    Object? filePath = _sentinel,
    Object? downloadedBitrateKbps = _sentinel,
    Object? fileSizeBytes = _sentinel,
    Object? downloadedQuality = _sentinel,
  }) {
    return TrackUI(
      uuidId: uuidId,
      filePath: filePath == _sentinel ? this.filePath : filePath as String?,
      createdAt: createdAt,
      lastUpdated: lastUpdated,
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      artistId: artistId,
      albumId: albumId,
      year: year,
      date: date,
      genre: genre,
      trackNumber: trackNumber,
      discNumber: discNumber,
      codec: codec,
      duration: duration,
      bitrateKbps: bitrateKbps,
      sampleRateHz: sampleRateHz,
      channels: channels,
      hasAlbumArt: hasAlbumArt,
      coverArtId: coverArtId,
      downloadedBitrateKbps: downloadedBitrateKbps == _sentinel
          ? this.downloadedBitrateKbps
          : downloadedBitrateKbps as int?,
      fileSizeBytes: fileSizeBytes == _sentinel
          ? this.fileSizeBytes
          : fileSizeBytes as int?,
      downloadedQuality: downloadedQuality == _sentinel
          ? this.downloadedQuality
          : downloadedQuality as String?,
    );
  }

  String get formattedDuration {
    final totalSeconds = duration.truncate();
    final seconds = totalSeconds % 60;
    final minutes = (totalSeconds ~/ 60) % 60;
    final hours = (totalSeconds ~/ 3600) % 24;
    final days = totalSeconds ~/ 86400;

    final ss = seconds.toString().padLeft(2, '0');
    if (days > 0) return '$days:${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$ss';
    if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
    return '$minutes:$ss';
  }

  factory TrackUI.fromQueryRow(QueryRow row) {
    return TrackUI(
      uuidId: row.read<String>('uuid_id'),
      filePath: row.readNullable<String>('file_path'),
      createdAt: row.read<int>('created_at'),
      lastUpdated: row.read<int>('last_updated'),
      title: row.readNullable<String>('title'),
      artist: row.readNullable<String>('artist'),
      album: row.readNullable<String>('album'),
      albumArtist: row.readNullable<String>('album_artist'),
      artistId: row.readNullable<int>('artist_id'),
      albumId: row.readNullable<int>('album_id'),
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
      coverArtId: row.readNullable<int>('cover_art_id'),
      downloadedBitrateKbps: row.readNullable<int>('downloaded_bitrate_kbps'),
      fileSizeBytes: row.readNullable<int>('file_size_bytes'),
      downloadedQuality: row.readNullable<String>('downloaded_quality'),
    );
  }

  factory TrackUI.fromDrift(Track track, TrackmetadataData meta) {
    return TrackUI(
      uuidId: track.uuidId,
      filePath: track.filePath,
      createdAt: track.createdAt,
      lastUpdated: track.lastUpdated,
      title: meta.title,
      artist: meta.artist,
      album: meta.album,
      albumArtist: meta.albumArtist,
      artistId: meta.artistId,
      albumId: meta.albumId,
      year: meta.year,
      date: meta.date,
      genre: meta.genre,
      trackNumber: meta.trackNumber,
      discNumber: meta.discNumber,
      codec: meta.codec,
      duration: meta.duration,
      bitrateKbps: meta.bitrateKbps,
      sampleRateHz: meta.sampleRateHz,
      channels: meta.channels,
      hasAlbumArt: meta.hasAlbumArt,
      coverArtId: meta.coverArtId,
      downloadedBitrateKbps: track.downloadedBitrateKbps,
      fileSizeBytes: track.fileSizeBytes,
      downloadedQuality: track.downloadedQuality,
    );
  }
}
