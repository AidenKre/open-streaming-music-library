"""List, count, change-stream and search reads, with their parameter types.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

from dataclasses import dataclass
from enum import auto, Flag
from typing import List, Literal, Optional

from app.core.owner import Owner, _owner_predicate, _require_owner
from app.core.operator_log import operator_logger
from app.database.core import DatabaseCore, _row_to_track, _track_select_columns
from app.models.album import Album
from app.models.artist import Artist
from app.models.track import Track

ALLOWED_METADATA_COLUMNS = [
    "title",
    "artist",
    "album",
    "album_artist",
    "year",
    "date",
    "genre",
    "track_number",
    "disc_number",
    "codec",
    "duration",
    "bitrate_kbps",
    "sample_rate_hz",
    "channels",
    "has_album_art",
    "cover_art_id",
]

ALLOWED_TRACK_COLUMNS = ["uuid_id", "created_at", "last_updated"]

ALLOWED_ALBUM_COLUMNS = ["id", "name", "artist", "artist_id", "year", "is_single_grouping"]
ALBUM_TEXT_COLUMNS = {"name", "artist"}
ALBUM_INTEGER_COLUMNS = {"id", "artist_id", "year", "is_single_grouping"}

ALLOWED_ARTIST_COLUMNS = ["id", "name"]
ARTIST_TEXT_COLUMNS = {"name"}

ALLOWED_OPERATORS = ["=", ">=", "<=", "<", ">"]


class SearchEntityType(Flag):
    TRACKS = auto()
    ARTISTS = auto()
    ALBUMS = auto()


@dataclass(frozen=True)
class SearchResults:
    tracks: List[Track]
    artists: List[Artist]
    albums: List[Album]


@dataclass(frozen=True)
class TrackChange:
    """One ordered entry in the revision-based change stream. ``track`` is the
    hydrated row for ``type == "upsert"`` and ``None`` for ``type == "delete"``."""

    type: Literal["upsert", "delete"]
    revision: int
    uuid_id: str
    track: Optional[Track] = None


@dataclass(frozen=True)
class SearchParameter:
    column: str
    operator: str
    value: Optional[str]

    def __post_init__(self):
        if self.operator not in ALLOWED_OPERATORS:
            raise ValueError("operator must be in ALLOWED_OPERATORS")

        if self.column not in set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS):
            raise ValueError(
                "column must be in ALLOWED_TRACK_COLUMNS or ALLOWED_METADATA_COLUMNS"
            )


@dataclass(frozen=True)
class OrderParameter:
    column: str
    isAscending: bool = True

    def __post_init__(self):
        if self.column not in set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS):
            raise ValueError(
                "column must be in ALLOWED_TRACK_COLUMNS or ALLOWED_METADATA_COLUMNS"
            )


@dataclass(frozen=True)
class RowFilterParameter:
    column: str
    value: Optional[str]

    def __post_init__(self):
        if self.column not in set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS):
            raise ValueError(
                "column must be in ALLOWED_TRACK_COLUMNS or ALLOWED_METADATA_COLUMNS"
            )


@dataclass(frozen=True)
class AlbumOrderParameter:
    column: str
    isAscending: bool = True
    nullsLast: bool = False

    def __post_init__(self):
        if self.column not in ALLOWED_ALBUM_COLUMNS:
            raise ValueError("column must be in ALLOWED_ALBUM_COLUMNS")


@dataclass(frozen=True)
class AlbumRowFilterParameter:
    column: str
    value: Optional[str]

    def __post_init__(self):
        if self.column not in ALLOWED_ALBUM_COLUMNS:
            raise ValueError("column must be in ALLOWED_ALBUM_COLUMNS")


@dataclass(frozen=True)
class ArtistOrderParameter:
    column: str
    isAscending: bool = True

    def __post_init__(self):
        if self.column not in ALLOWED_ARTIST_COLUMNS:
            raise ValueError("column must be in ALLOWED_ARTIST_COLUMNS")


@dataclass(frozen=True)
class ArtistRowFilterParameter:
    column: str
    value: Optional[str]

    def __post_init__(self):
        if self.column not in ALLOWED_ARTIST_COLUMNS:
            raise ValueError("column must be in ALLOWED_ARTIST_COLUMNS")


def prepare_fts_query(raw_query: str) -> str:
    terms = raw_query.strip().split()
    if not terms:
        return ""
    escaped = ['"' + t.replace('"', '""') + '"*' for t in terms]
    return " ".join(escaped)


def alias_map(column: str) -> str:
    if column in ALLOWED_METADATA_COLUMNS:
        return "tm"
    else:
        return "t"


# Sort-key cursor pagination logic. The app no longer keeps a copy of it
# (its own was deleted as unused, U15-FE-DB-B-02), so nothing there must match.
def filter_for_cursor(
    row_filter_list: List[RowFilterParameter],
    order_parameters: List[OrderParameter],
) -> tuple[str, List[str]]:
    columns = [param.column for param in row_filter_list]
    allowed_columns = set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS)
    input_columns = set(columns)
    invalid_search_columns = input_columns - allowed_columns

    if invalid_search_columns:
        raise ValueError("Invalid columns input to filter for cursor")

    if len(set(columns)) != len(columns):
        raise ValueError("Filtering by row requires all unique columns")

    order_columns = [op.column for op in order_parameters]
    if columns != order_columns:
        raise ValueError(
            "row_filter_parameters columns must match order_parameters columns"
        )

    constraints: List[str] = []
    values: List[str] = []

    for depth in range(len(row_filter_list)):
        equality_parts: List[str] = []
        equality_values: List[str] = []

        for i in range(depth):
            alias = alias_map(row_filter_list[i].column)
            col = row_filter_list[i].column
            value = row_filter_list[i].value
            if value is None:
                equality_parts.append(f'{alias}."{col}" IS NULL')
            else:
                equality_parts.append(f'{alias}."{col}" = ?')
                equality_values.append(value)

        alias = alias_map(row_filter_list[depth].column)
        col = row_filter_list[depth].column
        cursor_value = row_filter_list[depth].value

        if cursor_value is None:
            # NULL: for ASC, any non-null value comes after NULL; for DESC, nothing is less than NULL
            if order_parameters[depth].isAscending:
                final_part = f'{alias}."{col}" IS NOT NULL'
            else:
                # Skip this depth entirely — no rows can be "less than" NULL
                continue
            all_parts = equality_parts + [final_part]
            all_values = equality_values
        else:
            op = ">" if order_parameters[depth].isAscending else "<"
            final_part = f'{alias}."{col}" {op} ?'
            all_parts = equality_parts + [final_part]
            all_values = equality_values + [cursor_value]

        if len(all_parts) == 1:
            constraints.append(all_parts[0])
        else:
            constraints.append("(" + " AND ".join(all_parts) + ")")
        values.extend(all_values)

    if not constraints:
        return ("", values)

    return (" OR ".join(constraints), values)


def _album_col_ref(col: str) -> str:
    """Return a table-qualified column reference for album queries.

    The get_albums query joins ``albums a`` with ``artists ar`` and aliases
    ``ar.name AS artist``.  Using a bare ``"name"`` would be ambiguous, so
    columns that live on the albums table are prefixed with ``a.``.
    """
    # "artist" maps to ar."name" — the actual column on the joined artists
    # table.  A SELECT alias cannot be used in WHERE clauses.
    if col == "artist":
        return 'ar."name"'
    # Everything else lives on the albums table.
    return f'a."{col}"'


def filter_for_album_cursor(
    row_filter_list: List[AlbumRowFilterParameter],
    order_parameters: List[AlbumOrderParameter],
) -> tuple[str, List[str]]:
    if not row_filter_list:
        return ("", [])

    columns = [param.column for param in row_filter_list]
    input_columns = set(columns)
    invalid_columns = input_columns - set(ALLOWED_ALBUM_COLUMNS)

    if invalid_columns:
        raise ValueError("Invalid columns input to filter for album cursor")

    if len(set(columns)) != len(columns):
        raise ValueError("Filtering by row requires all unique columns")

    order_columns = [op.column for op in order_parameters]
    if columns != order_columns:
        raise ValueError(
            "row_filter_parameters columns must match order_parameters columns"
        )

    constraints: List[str] = []
    values: List[str] = []

    for depth in range(len(row_filter_list)):
        equality_parts: List[str] = []
        equality_values: List[str] = []

        for i in range(depth):
            col = row_filter_list[i].column
            value = row_filter_list[i].value
            col_ref = _album_col_ref(col)
            collate = " COLLATE NOCASE" if col in ALBUM_TEXT_COLUMNS else ""
            param = "CAST(? AS INTEGER)" if col in ALBUM_INTEGER_COLUMNS else "?"
            if value is None:
                equality_parts.append(f'{col_ref} IS NULL')
            else:
                equality_parts.append(f'{col_ref}{collate} = {param}')
                equality_values.append(value)

        col = row_filter_list[depth].column
        col_ref = _album_col_ref(col)
        cursor_value = row_filter_list[depth].value
        nulls_last = order_parameters[depth].nullsLast
        collate = " COLLATE NOCASE" if col in ALBUM_TEXT_COLUMNS else ""
        param = "CAST(? AS INTEGER)" if col in ALBUM_INTEGER_COLUMNS else "?"

        if cursor_value is None:
            if nulls_last:
                # NULLs sort last: nothing comes after NULL
                continue
            elif order_parameters[depth].isAscending:
                # NULLs sort first (default): any non-null comes after NULL
                final_part = f'{col_ref} IS NOT NULL'
            else:
                # DESC with NULLs first: nothing is "less than" NULL
                continue
            all_parts = equality_parts + [final_part]
            all_values = equality_values
        else:
            op = ">" if order_parameters[depth].isAscending else "<"
            if nulls_last:
                # Non-NULL cursor with nullsLast: greater values OR NULLs come after
                final_part = f'({col_ref}{collate} {op} {param} OR {col_ref} IS NULL)'
                all_parts = equality_parts + [final_part]
                all_values = equality_values + [cursor_value]
            else:
                final_part = f'{col_ref}{collate} {op} {param}'
                all_parts = equality_parts + [final_part]
                all_values = equality_values + [cursor_value]

        if len(all_parts) == 1:
            constraints.append(all_parts[0])
        else:
            constraints.append("(" + " AND ".join(all_parts) + ")")
        values.extend(all_values)

    if not constraints:
        return ("", values)

    return (" OR ".join(constraints), values)


def filter_for_artist_cursor(
    row_filter_list: List[ArtistRowFilterParameter],
    order_parameters: List[ArtistOrderParameter],
) -> tuple[str, List[str]]:
    if not row_filter_list:
        return ("", [])

    columns = [param.column for param in row_filter_list]
    input_columns = set(columns)
    invalid_columns = input_columns - set(ALLOWED_ARTIST_COLUMNS)

    if invalid_columns:
        raise ValueError("Invalid columns input to filter for artist cursor")

    if len(set(columns)) != len(columns):
        raise ValueError("Filtering by row requires all unique columns")

    order_columns = [op.column for op in order_parameters]
    if columns != order_columns:
        raise ValueError(
            "row_filter_parameters columns must match order_parameters columns"
        )

    constraints: List[str] = []
    values: List[str] = []

    for depth in range(len(row_filter_list)):
        equality_parts: List[str] = []
        equality_values: List[str] = []

        for i in range(depth):
            col = row_filter_list[i].column
            value = row_filter_list[i].value
            collate = " COLLATE NOCASE" if col in ARTIST_TEXT_COLUMNS else ""
            if value is None:
                equality_parts.append(f'"{col}" IS NULL')
            else:
                equality_parts.append(f'"{col}"{collate} = ?')
                equality_values.append(value)

        col = row_filter_list[depth].column
        cursor_value = row_filter_list[depth].value
        collate = " COLLATE NOCASE" if col in ARTIST_TEXT_COLUMNS else ""

        if cursor_value is None:
            if order_parameters[depth].isAscending:
                final_part = f'"{col}" IS NOT NULL'
            else:
                continue
            all_parts = equality_parts + [final_part]
            all_values = equality_values
        else:
            op = ">" if order_parameters[depth].isAscending else "<"
            final_part = f'"{col}"{collate} {op} ?'
            all_parts = equality_parts + [final_part]
            all_values = equality_values + [cursor_value]

        if len(all_parts) == 1:
            constraints.append(all_parts[0])
        else:
            constraints.append("(" + " AND ".join(all_parts) + ")")
        values.extend(all_values)

    if not constraints:
        return ("", values)

    return (" OR ".join(constraints), values)


class BrowsePart(DatabaseCore):
    """The reads behind the browse routes: tracks, artists and albums with their
    counts, the revision-ordered change stream, full-text search."""

    def get_tracks(
        self,
        search_parameters: List[SearchParameter] | None = None,
        order_parameters: List[OrderParameter] | None = None,
        row_filter_parameters: List[RowFilterParameter] | None = None,
        artist_id: Optional[int] = None,
        album_id: Optional[int] = None,
        timeout: float = 5,
        limit: int = 100,
        offset: int = 0,
        *,
        owner_id: Owner,
    ) -> List[Track]:
        if search_parameters is None:
            search_parameters = []
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if album_id is not None and artist_id is None:
            raise ValueError("Cannot filter by album without artist")

        if limit <= 0 or limit > 1000 or offset < 0:
            operator_logger.warning(
                "Limit %s or Offset %s was set incorrectly for database.get_tracks",
                limit, offset,
            )
            raise ValueError

        allowed_columns = set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS)
        search_columns = set([param.column for param in search_parameters])
        order_columns = set([order.column for order in order_parameters])
        invalid_search_columns = search_columns - allowed_columns
        invalid_order_columns = order_columns - allowed_columns

        if invalid_search_columns:
            operator_logger.warning(
                "columns %s are not allowed as a search parameter",
                invalid_search_columns,
            )
            raise ValueError

        if invalid_order_columns:
            operator_logger.warning(
                "columns %s are not allowed as a search parameter",
                invalid_order_columns,
            )
            raise ValueError

        search_query = (
            f"SELECT {_track_select_columns()} "
            "FROM trackmetadata AS tm "
            "JOIN tracks AS t ON "
            " tm.uuid_id = t.uuid_id"
        )
        search_clauses = []
        search_values: list = []

        for param in search_parameters:
            column = param.column
            value = param.value
            operator = param.operator
            alias = alias_map(column)
            if value is None:
                search_clauses.append(f'{alias}."{column}" IS NULL')
            else:
                search_clauses.append(f'{alias}."{column}" {operator} ?')
                search_values.append(value)

        owner_clause, owner_values = _owner_predicate("t.owner_id", owner_id)
        if owner_clause:
            search_clauses.append(owner_clause)
            search_values.extend(owner_values)

        if artist_id is not None:
            search_clauses.append('tm."artist_id" = ?')
            search_values.append(artist_id)
        if album_id is not None:
            search_clauses.append('tm."album_id" = ?')
            search_values.append(album_id)

        if row_filter_parameters and order_parameters:
            cursor_clause, cursor_values = filter_for_cursor(
                row_filter_parameters, order_parameters
            )
            if cursor_clause:
                search_clauses.append("(" + cursor_clause + ")")
                search_values.extend(cursor_values)

        if search_clauses:
            search_query += " WHERE " + " AND ".join(search_clauses)

        order_clauses = []

        for order in order_parameters:
            column = order.column
            value = "ASC" if order.isAscending else "DESC"
            alias = alias_map(column)
            order_clauses.append(f'{alias}."{column}" {value.upper()}')

        if order_clauses:
            search_query += " ORDER BY " + " , ".join(order_clauses)

        search_query += " LIMIT " + str(limit) + " OFFSET " + str(offset)

        try:
            with self._connection(timeout=timeout) as conn:
                rows = (
                    conn.cursor().execute(search_query, tuple(search_values)).fetchall()
                )
        except Exception as e:
            operator_logger.error(
                "Failed to search database. search_parameters: %s. Exception: %s",
                search_parameters, e,
            )
            return []

        tracks: List[Track] = [_row_to_track(row) for row in rows]

        return tracks

    def get_changes(
        self, after_revision: int, limit: int, timeout: float = 5, *, owner_id: int
    ) -> tuple[List[TrackChange], int, Optional[int]]:
        """Return up to ``limit`` change entries with ``revision >
        after_revision`` (ascending), the current latest revision, and the
        next cursor (the highest revision consumed when the raw stream filled
        the page, else ``None``).

        Upserts (live ``tracks``) and deletes (``track_tombstones``) share one
        revision space and interleave by revision, so a single ordered stream
        carries both — deletes are no longer a first-page side channel and
        surface on whichever page their revision lands on.

        ``next_cursor`` is derived from the *raw* stream length, not the
        returned ``changes``: an upsert whose track was concurrently deleted
        between this query and the hydration JOIN is dropped from ``changes``,
        which would otherwise shrink the page below ``limit`` and falsely
        signal "caught up", stranding higher-revision rows until the next
        sync. Advancing past the consumed revision is safe — the dropped
        row's delete carries a higher revision and arrives on a later page.

        Only the owner's rows stream, and ``latest`` is the owner's highest
        revision (the revision counter itself stays global)."""
        _require_owner(owner_id)
        try:
            with self._connection(timeout=timeout) as conn:
                # Two single-table MAX subqueries, so each is one seek on its
                # (owner_id, revision) index; a MAX over a UNION ALL reads every
                # one of the owner's rows.
                latest = conn.execute(
                    "SELECT max("
                    "COALESCE((SELECT MAX(revision) FROM tracks WHERE owner_id = ?), 0), "
                    "COALESCE((SELECT MAX(revision) FROM track_tombstones WHERE owner_id = ?), 0))",
                    (owner_id, owner_id),
                ).fetchone()[0]
                stream = conn.execute(
                    "SELECT 'upsert' AS change_type, revision, uuid_id FROM tracks "
                    "WHERE revision > ? AND owner_id = ? "
                    "UNION ALL "
                    "SELECT 'delete' AS change_type, revision, uuid_id "
                    "FROM track_tombstones WHERE revision > ? AND owner_id = ? "
                    "ORDER BY revision ASC LIMIT ?",
                    (after_revision, owner_id, after_revision, owner_id, limit),
                ).fetchall()

                upsert_uuids = [
                    r["uuid_id"] for r in stream if r["change_type"] == "upsert"
                ]
                track_by_uuid: dict[str, Track] = {}
                if upsert_uuids:
                    placeholders = ",".join("?" * len(upsert_uuids))
                    hydrated = conn.execute(
                        f"SELECT {_track_select_columns()} "
                        "FROM trackmetadata AS tm "
                        "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                        f"WHERE t.uuid_id IN ({placeholders}) AND t.owner_id = ?",
                        (*upsert_uuids, owner_id),
                    ).fetchall()
                    track_by_uuid = {
                        row["uuid_id"]: _row_to_track(row) for row in hydrated
                    }

                changes: List[TrackChange] = []
                for r in stream:
                    if r["change_type"] == "upsert":
                        track = track_by_uuid.get(r["uuid_id"])
                        if track is None:
                            # Raced with a concurrent delete; the delete entry
                            # carries a higher revision and will be streamed.
                            continue
                        changes.append(
                            TrackChange(
                                type="upsert",
                                revision=r["revision"],
                                uuid_id=r["uuid_id"],
                                track=track,
                            )
                        )
                    else:
                        changes.append(
                            TrackChange(
                                type="delete",
                                revision=r["revision"],
                                uuid_id=r["uuid_id"],
                            )
                        )

                # Normally, a cursor is needed only when the raw stream hit
                # the page limit. If hydration dropped raw upsert rows, return
                # a cursor even on a short final page so clients can advance
                # past the consumed revision instead of requesting it forever.
                last_consumed_revision = stream[-1]["revision"] if stream else None
                last_returned_revision = (
                    changes[-1].revision if changes else after_revision
                )
                should_advance_past_dropped_rows = (
                    last_consumed_revision is not None
                    and last_consumed_revision > last_returned_revision
                )
                next_cursor = (
                    last_consumed_revision
                    if len(stream) == limit or should_advance_past_dropped_rows
                    else None
                )
                return changes, latest, next_cursor
        except Exception as e:
            # Re-raise so the endpoint surfaces a 5xx. Swallowing here would
            # return an empty page, which the client reads as "caught up" and
            # silently stops syncing — masking a transient DB failure.
            operator_logger.error("Failed to get changes after revision %s: %s", after_revision, e)
            raise

    def get_tracks_count(
        self,
        search_parameters: List[SearchParameter] | None = None,
        order_parameters: List[OrderParameter] | None = None,
        row_filter_parameters: List[RowFilterParameter] | None = None,
        artist_id: Optional[int] = None,
        album_id: Optional[int] = None,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> int | None:
        if search_parameters is None:
            search_parameters = []
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if album_id is not None and artist_id is None:
            raise ValueError("Cannot filter by album without artist")

        search_query = (
            "SELECT COUNT(*) FROM tracks as t "
            "JOIN trackmetadata AS tm ON "
            " t.uuid_id = tm.uuid_id"
        )

        search_clauses = []
        search_values: list = []

        for param in search_parameters:
            column = param.column
            value = param.value
            operator = param.operator
            alias = alias_map(column)
            if value is None:
                search_clauses.append(f'{alias}."{column}" IS NULL')
            else:
                search_clauses.append(f'{alias}."{column}" {operator} ?')
                search_values.append(value)

        owner_clause, owner_values = _owner_predicate("t.owner_id", owner_id)
        if owner_clause:
            search_clauses.append(owner_clause)
            search_values.extend(owner_values)

        if artist_id is not None:
            search_clauses.append('tm."artist_id" = ?')
            search_values.append(artist_id)
        if album_id is not None:
            search_clauses.append('tm."album_id" = ?')
            search_values.append(album_id)

        if row_filter_parameters and order_parameters:
            cursor_clause, cursor_values = filter_for_cursor(
                row_filter_parameters, order_parameters
            )
            if cursor_clause:
                search_clauses.append("(" + cursor_clause + ")")
                search_values.extend(cursor_values)

        if search_clauses:
            search_query += " WHERE " + " AND ".join(search_clauses)

        try:
            with self._connection(timeout=timeout) as conn:
                count = int(
                    conn.cursor()
                    .execute(search_query, tuple(search_values))
                    .fetchone()[0]
                )
            return count
        except Exception as e:
            operator_logger.error("Failed to get count from database while executing query: %s", e)
            return None

    def get_artists(
        self,
        order_parameters: List[ArtistOrderParameter] | None = None,
        row_filter_parameters: List[ArtistRowFilterParameter] | None = None,
        limit: int = 100,
        offset: int = 0,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> List[Artist] | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if limit <= 0 or limit > 1000 or offset < 0:
            operator_logger.warning(
                "Limit %s or Offset %s was set incorrectly for database.get_artists",
                limit, offset,
            )
            raise ValueError
        parameters: list = []

        query = "SELECT id, name FROM artists "

        owner_clause, owner_values = _owner_predicate("owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        # Cursor filter
        cursor_clause, cursor_values = filter_for_artist_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)
        if where_clauses:
            query += "WHERE " + " AND ".join(where_clauses) + " "

        # ORDER BY
        order_parts: list[str] = []
        for param in order_parameters:
            col = param.column
            direction = "ASC" if param.isAscending else "DESC"
            collate = " COLLATE NOCASE" if col in ARTIST_TEXT_COLUMNS else ""
            order_parts.append(f'"{col}"{collate} {direction}')

        if order_parts:
            query += "ORDER BY " + ", ".join(order_parts) + " "
        else:
            query += "ORDER BY name COLLATE NOCASE ASC "

        query += "LIMIT ? OFFSET ?"
        parameters.extend([limit, offset])

        try:
            with self._connection(timeout=timeout) as conn:
                rows = conn.cursor().execute(query, tuple(parameters)).fetchall()
            return [Artist(id=row["id"], name=row["name"]) for row in rows]
        except Exception as e:
            operator_logger.error("Error executing artist query: %s", e)
            return None

    def get_artists_count(
        self,
        order_parameters: List[ArtistOrderParameter] | None = None,
        row_filter_parameters: List[ArtistRowFilterParameter] | None = None,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> int | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        parameters: list = []

        query = "SELECT COUNT(*) FROM artists "

        owner_clause, owner_values = _owner_predicate("owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        cursor_clause, cursor_values = filter_for_artist_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)
        if where_clauses:
            query += "WHERE " + " AND ".join(where_clauses) + " "

        try:
            with self._connection(timeout=timeout) as conn:
                artist_count = int(
                    conn.cursor().execute(query, tuple(parameters)).fetchone()[0]
                )
            return artist_count
        except Exception as e:
            operator_logger.error("Unable to fetch artist counts. %s", e)
            return None

    def get_albums(
        self,
        artist_id: Optional[int] = None,
        order_parameters: List[AlbumOrderParameter] | None = None,
        row_filter_parameters: List[AlbumRowFilterParameter] | None = None,
        limit: int = 100,
        offset: int = 0,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> List[Album] | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if limit <= 0 or limit > 1000 or offset < 0:
            operator_logger.warning(
                "Limit %s or Offset %s was set incorrectly for database.get_albums",
                limit, offset,
            )
            raise ValueError

        parameters: list = []

        query = (
            "SELECT a.id, a.name, ar.name AS artist, a.artist_id, "
            'a."year", a.is_single_grouping '
            "FROM albums a "
            "JOIN artists ar ON a.artist_id = ar.id"
        )

        owner_clause, owner_values = _owner_predicate("ar.owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        if artist_id is not None:
            where_clauses.append("a.artist_id = ?")
            parameters.append(artist_id)

        # Cursor filter
        cursor_clause, cursor_values = filter_for_album_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)

        if where_clauses:
            query += " WHERE " + " AND ".join(where_clauses)

        # ORDER BY
        order_parts: list[str] = []
        for param in order_parameters:
            col = param.column
            col_ref = _album_col_ref(col)
            direction = "ASC" if param.isAscending else "DESC"
            collate = " COLLATE NOCASE" if col in ALBUM_TEXT_COLUMNS else ""
            if param.nullsLast:
                order_parts.append(f'{col_ref} IS NULL ASC')
            order_parts.append(f'{col_ref}{collate} {direction}')

        if order_parts:
            query += " ORDER BY " + ", ".join(order_parts)

        query += " LIMIT ? OFFSET ?"
        parameters.extend([limit, offset])

        try:
            with self._connection(timeout=timeout) as conn:
                album_rows = (
                    conn.cursor().execute(query, tuple(parameters)).fetchall()
                )
        except Exception as e:
            operator_logger.error("Failed to retrieve albums: %s", e)
            return None

        return [
            Album(
                id=row["id"],
                name=row["name"],
                artist=row["artist"],
                artist_id=row["artist_id"],
                year=row["year"] if row["year"] is not None else None,
                is_single_grouping=bool(row["is_single_grouping"]),
            )
            for row in album_rows
        ]

    def get_albums_count(
        self,
        artist_id: Optional[int] = None,
        order_parameters: List[AlbumOrderParameter] | None = None,
        row_filter_parameters: List[AlbumRowFilterParameter] | None = None,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> int | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []

        parameters: list = []

        query = (
            "SELECT COUNT(*) FROM albums a "
            "JOIN artists ar ON a.artist_id = ar.id"
        )

        owner_clause, owner_values = _owner_predicate("ar.owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        if artist_id is not None:
            where_clauses.append("a.artist_id = ?")
            parameters.append(artist_id)

        cursor_clause, cursor_values = filter_for_album_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)

        if where_clauses:
            query += " WHERE " + " AND ".join(where_clauses)

        try:
            with self._connection(timeout=timeout) as conn:
                album_count = int(
                    conn.cursor().execute(query, tuple(parameters)).fetchone()[0]
                )
            return album_count
        except Exception as e:
            operator_logger.error("Failed to retrieve album counts: %s", e)
            return None

    def get_search_results(
        self,
        query: str,
        return_types: SearchEntityType = SearchEntityType.TRACKS | SearchEntityType.ARTISTS | SearchEntityType.ALBUMS,
        limit_per_type: int = 10,
        timeout: float = 5,
        *,
        owner_id: int,
    ) -> SearchResults:
        _require_owner(owner_id)
        fts_query = prepare_fts_query(query)
        if not fts_query:
            return SearchResults(tracks=[], artists=[], albums=[])

        result_tracks: List[Track] = []
        result_artists: List[Artist] = []
        result_albums: List[Album] = []

        try:
            with self._connection(timeout=timeout) as conn:
                if SearchEntityType.TRACKS in return_types:
                    track_rows = conn.execute(
                        "SELECT f.rowid FROM fts_tracks f "
                        "JOIN trackmetadata tm ON tm.track_id = f.rowid "
                        "JOIN tracks t ON t.uuid_id = tm.uuid_id "
                        "WHERE fts_tracks MATCH ? AND t.owner_id = ? "
                        "ORDER BY f.rank LIMIT ?",
                        (fts_query, owner_id, limit_per_type),
                    ).fetchall()
                    if track_rows:
                        track_ids = [r["rowid"] for r in track_rows]
                        placeholders = ", ".join("?" for _ in track_ids)
                        full_rows = conn.execute(
                            f"SELECT {_track_select_columns('tm.track_id')} "
                            "FROM trackmetadata AS tm "
                            "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                            f"WHERE tm.track_id IN ({placeholders}) AND t.owner_id = ?",
                            (*track_ids, owner_id),
                        ).fetchall()
                        # Preserve FTS rank order
                        id_order = {tid: i for i, tid in enumerate(track_ids)}
                        full_rows_sorted = sorted(
                            full_rows,
                            key=lambda r: id_order.get(r["track_id"], 999),
                        )
                        for row in full_rows_sorted:
                            result_tracks.append(_row_to_track(row))

                if SearchEntityType.ARTISTS in return_types:
                    artist_rows = conn.execute(
                        "SELECT f.rowid FROM fts_artists f "
                        "JOIN artists a ON a.id = f.rowid "
                        "WHERE fts_artists MATCH ? AND a.owner_id = ? "
                        "ORDER BY f.rank LIMIT ?",
                        (fts_query, owner_id, limit_per_type),
                    ).fetchall()
                    if artist_rows:
                        artist_ids = [r["rowid"] for r in artist_rows]
                        placeholders = ", ".join("?" for _ in artist_ids)
                        full_rows = conn.execute(
                            f"SELECT id, name FROM artists WHERE id IN ({placeholders}) "
                            "AND owner_id = ?",
                            (*artist_ids, owner_id),
                        ).fetchall()
                        id_order = {aid: i for i, aid in enumerate(artist_ids)}
                        full_rows_sorted = sorted(
                            full_rows, key=lambda r: id_order.get(r["id"], 999)
                        )
                        result_artists = [
                            Artist(id=r["id"], name=r["name"])
                            for r in full_rows_sorted
                        ]

                if SearchEntityType.ALBUMS in return_types:
                    album_rows = conn.execute(
                        "SELECT f.rowid FROM fts_albums f "
                        "JOIN albums al ON al.id = f.rowid "
                        "JOIN artists ar ON ar.id = al.artist_id "
                        "WHERE fts_albums MATCH ? AND ar.owner_id = ? "
                        "ORDER BY f.rank LIMIT ?",
                        (fts_query, owner_id, limit_per_type),
                    ).fetchall()
                    if album_rows:
                        album_ids = [r["rowid"] for r in album_rows]
                        placeholders = ", ".join("?" for _ in album_ids)
                        full_rows = conn.execute(
                            "SELECT a.id, a.name, ar.name AS artist, a.artist_id, "
                            'a."year", a.is_single_grouping '
                            "FROM albums a "
                            "JOIN artists ar ON a.artist_id = ar.id "
                            f"WHERE a.id IN ({placeholders}) AND ar.owner_id = ?",
                            (*album_ids, owner_id),
                        ).fetchall()
                        id_order = {aid: i for i, aid in enumerate(album_ids)}
                        full_rows_sorted = sorted(
                            full_rows, key=lambda r: id_order.get(r["id"], 999)
                        )
                        result_albums = [
                            Album(
                                id=r["id"],
                                name=r["name"],
                                artist=r["artist"],
                                artist_id=r["artist_id"],
                                year=r["year"],
                                is_single_grouping=bool(r["is_single_grouping"]),
                            )
                            for r in full_rows_sorted
                        ]

        except Exception as e:
            operator_logger.error("Search failed: %s", e)

        return SearchResults(
            tracks=result_tracks, artists=result_artists, albums=result_albums
        )
