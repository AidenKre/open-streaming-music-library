part of 'database.dart';

// ── Column allowlists (mirrors backend app/database/browse.py) ──────────

const allowedMetadataColumns = {
  'title',
  'artist',
  'album',
  'album_artist',
  'year',
  'date',
  'genre',
  'track_number',
  'disc_number',
  'codec',
  'duration',
  'bitrate_kbps',
  'sample_rate_hz',
  'channels',
  'has_album_art',
  'cover_art_id',
};

const allowedTrackColumns = {'uuid_id', 'created_at', 'last_updated'};

// The editable-column set lives in models/editable_fields.dart, derived from
// the same descriptor list that drives the offline default form schema.

const allowedAlbumColumns = {
  'id',
  'name',
  'artist',
  'artist_id',
  'year',
  'is_single_grouping',
};
const albumTextColumns = {'name', 'artist'};

const allowedArtistColumns = {'id', 'name'};
const artistTextColumns = {'name'};

const allowedOperators = {'=', '>=', '<=', '<', '>'};

// ── Parameter classes ───────────────────────────────────────────────────

class SearchParameter {
  final String column;
  final String operator;
  final Object? value;

  SearchParameter({required this.column, required this.operator, this.value}) {
    if (!allowedOperators.contains(operator)) {
      throw ArgumentError('operator must be in allowedOperators');
    }
    if (!allowedMetadataColumns.contains(column) &&
        !allowedTrackColumns.contains(column)) {
      throw ArgumentError(
        'column must be in allowedMetadataColumns or allowedTrackColumns',
      );
    }
  }
}

class OrderParameter {
  final String column;
  final bool isAscending;
  final int? nullsAs;
  final bool caseInsensitive;

  OrderParameter({
    required this.column,
    this.isAscending = true,
    this.nullsAs,
    this.caseInsensitive = false,
  }) {
    if (!allowedMetadataColumns.contains(column) &&
        !allowedTrackColumns.contains(column)) {
      throw ArgumentError(
        'column must be in allowedMetadataColumns or allowedTrackColumns',
      );
    }
  }
}

class AlbumOrderParameter {
  final String column;
  final bool isAscending;
  final bool nullsLast;

  AlbumOrderParameter({
    required this.column,
    this.isAscending = true,
    this.nullsLast = false,
  }) {
    if (!allowedAlbumColumns.contains(column)) {
      throw ArgumentError('column must be in allowedAlbumColumns');
    }
  }
}

class ArtistOrderParameter {
  final String column;
  final bool isAscending;

  ArtistOrderParameter({required this.column, this.isAscending = true}) {
    if (!allowedArtistColumns.contains(column)) {
      throw ArgumentError('column must be in allowedArtistColumns');
    }
  }
}

// ── Helper functions ────────────────────────────────────────────────────

String aliasMap(String column) {
  return allowedMetadataColumns.contains(column) ? 'tm' : 't';
}

/// The one ORDER BY body for track queries (browse windows and the queue
/// insert), so every list orders a given [OrderParameter] list the
/// same way. [OrderParameter.nullsAs] sorts NULL as that value (COALESCE);
/// [OrderParameter.caseInsensitive] compares with `COLLATE NOCASE`.
String trackOrderClause(List<OrderParameter> orderBy) {
  return orderBy
      .map((o) {
        final column = '${aliasMap(o.column)}."${o.column}"';
        final key = o.nullsAs == null
            ? column
            : 'COALESCE($column, ${o.nullsAs})';
        final collate = o.caseInsensitive ? ' COLLATE NOCASE' : '';
        return '$key$collate ${o.isAscending ? 'ASC' : 'DESC'}';
      })
      .join(', ');
}

Variable _variableFrom(Object value) {
  if (value is String) return Variable.withString(value);
  if (value is int) return Variable.withInt(value);
  if (value is double) return Variable.withReal(value);
  throw ArgumentError('Unsupported variable type: ${value.runtimeType}');
}

/// Maps album column names to table-qualified SQL references.
/// The get_albums query joins `albums a` with `artists ar`, so "artist"
/// maps to `ar."name"` (the actual column, not the SELECT alias).
String _albumColRef(String col) {
  if (col == 'artist') return 'ar."name"';
  return 'a."$col"';
}
