import 'package:drift/drift.dart';

class AlbumUI {
  final int id;
  final String? name;
  final String? artist;
  final int artistId;
  final int? year;
  final bool isSingleGrouping;

  const AlbumUI({
    required this.id,
    this.name,
    this.artist,
    required this.artistId,
    this.year,
    this.isSingleGrouping = false,
  });

  factory AlbumUI.fromQueryRow(QueryRow row) {
    return AlbumUI(
      id: row.read<int>('id'),
      name: row.readNullable<String>('name'),
      artist: row.readNullable<String>('artist'),
      artistId: row.read<int>('artist_id'),
      year: row.readNullable<int>('year'),
      isSingleGrouping: row.read<int>('is_single_grouping') == 1,
    );
  }
}
