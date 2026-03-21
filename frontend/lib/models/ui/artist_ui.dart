import 'package:drift/drift.dart';

class ArtistUI {
  final int id;
  final String name;

  const ArtistUI({
    required this.id,
    required this.name,
  });

  factory ArtistUI.fromQueryRow(QueryRow row) {
    return ArtistUI(
      id: row.read<int>('id'),
      name: row.read<String>('name'),
    );
  }
}
