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

  bool get isDownloaded => filePath != null;

  const TrackUI({
    required this.uuidId,
    this.filePath,
    required this.createdAt,
    required this.lastUpdated,
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
    );
  }
}
