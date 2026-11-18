part of 'database.dart';

mixin _AutocompleteQueries on _$AppDatabase {
  // ── Metadata autocomplete ─────────────────────────────────────────────
  //
  // Case-insensitive prefix suggestions drawn from the synced library, for the
  // Get Info form. Artist / album match `name_lower` with LIKE, which is
  // case-insensitive while the `name_lower` indexes are not, so they scan the
  // (small) entity tables; genre has no entity table so it rides the NOCASE
  // `idx_genre_nocase`.

  /// Suggestions for the `artist` and `album_artist` fields.
  Future<List<String>> artistSuggestions(String prefix, {int limit = 8}) {
    return _prefixSuggestions(
      "SELECT name FROM artists WHERE name_lower LIKE ? ESCAPE '\\' "
      'ORDER BY name LIMIT ?',
      column: 'name',
      pattern: '${_escapeLike(prefix.trim().toLowerCase())}%',
      rawPrefix: prefix,
      limit: limit,
      reads: {artists},
    );
  }

  /// Suggestions for the `album` field.
  Future<List<String>> albumSuggestions(String prefix, {int limit = 8}) {
    return _prefixSuggestions(
      'SELECT DISTINCT name FROM albums '
      "WHERE name IS NOT NULL AND name_lower LIKE ? ESCAPE '\\' "
      'ORDER BY name LIMIT ?',
      column: 'name',
      pattern: '${_escapeLike(prefix.trim().toLowerCase())}%',
      rawPrefix: prefix,
      limit: limit,
      reads: {albums},
    );
  }

  /// Suggestions for the `genre` field.
  Future<List<String>> genreSuggestions(String prefix, {int limit = 8}) {
    return _prefixSuggestions(
      'SELECT DISTINCT genre FROM trackmetadata '
      "WHERE genre IS NOT NULL AND genre LIKE ? ESCAPE '\\' "
      'ORDER BY genre LIMIT ?',
      column: 'genre',
      pattern: '${_escapeLike(prefix.trim())}%',
      rawPrefix: prefix,
      limit: limit,
      reads: {trackmetadata},
    );
  }

  Future<List<String>> _prefixSuggestions(
    String sql, {
    required String column,
    required String pattern,
    required String rawPrefix,
    required int limit,
    required Set<ResultSetImplementation<dynamic, dynamic>> reads,
  }) async {
    if (rawPrefix.trim().isEmpty) return const [];
    final rows = await customSelect(
      sql,
      variables: [Variable.withString(pattern), Variable.withInt(limit)],
      readsFrom: reads,
    ).get();
    return rows.map((r) => r.read<String>(column)).toList();
  }

  /// Escapes the LIKE metacharacters in user input so a typed `%` or `_` is a
  /// literal, not a wildcard (paired with `ESCAPE '\'` in the queries).
  static String _escapeLike(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
