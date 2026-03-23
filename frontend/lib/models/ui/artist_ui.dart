import 'package:drift/drift.dart';

class ArtistUI {
  final int id;
  final String name;
  final int? coverArtId;

  const ArtistUI({
    required this.id,
    required this.name,
    this.coverArtId,
  });

  factory ArtistUI.fromQueryRow(QueryRow row) {
    return ArtistUI(
      id: row.read<int>('id'),
      name: row.read<String>('name'),
      coverArtId: row.readNullable<int>('cover_art_id'),
    );
  }
}
