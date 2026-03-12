import 'package:drift/drift.dart';

class AlbumUI {
  final String? title;
  final String? artist;
  final int? year;
  final bool isSingleGrouping;

  const AlbumUI({
    this.title,
    this.artist,
    this.year,
    this.isSingleGrouping = false,
  });

  factory AlbumUI.fromQueryRow(QueryRow row) {
    return AlbumUI(
      title: row.readNullable<String>('album'),
      artist: row.readNullable<String>('artist'),
      year: row.readNullable<int>('year'),
      isSingleGrouping: row.read<int>('is_single_grouping') == 1,
    );
  }
}
