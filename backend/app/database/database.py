import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

# TODO: refactor try blocks to not be so atomic
# TODO: actually catch real sqlite excpetions from the try blocks
# TODO: use finally for the try blocks
# TODO: do not let connect_to_database return None. raising and expection is probably fine, since consumers of the function should be try catching

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
]

ALLOWED_TRACK_COLUMNS = ["uuid_id", "created_at", "last_updated"]

ALLOWED_OPERATORS = ["=", ">=", "<=", "<", ">"]


@dataclass(frozen=True)
class DatabaseContext:
    database_path: Path
    init_sql_path: Path


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


class Database:
    def __init__(self, context: DatabaseContext):
        self.context = context

    def connect_to_database(self, timeout: float = 5) -> sqlite3.Connection | None:
        database_path = self.context.database_path
        conn = None
        try:
            conn = sqlite3.connect(database_path, timeout=timeout)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.commit()
            return conn

        except Exception as e:
            print(
                f"Error connecting to the sqlite database. database path: {database_path} Exception: {e}"
            )
            return None

    def initialize(self) -> bool:
        # TODO: Create database migration logic when I actually need to migrate a database
        if self.context.database_path.exists():
            print("Database already exists, so skipping")
            return True
        conn = None
        try:
            conn = self.connect_to_database()
        except Exception as e:
            print(e)
            return False

        if not conn:
            print(
                "Unable to connect to the database, connect_to_database returned false"
            )
            return False

        with open(self.context.init_sql_path, "r") as f:
            init_script = f.read()

        try:
            conn.executescript(init_script)
        except Exception as e:
            print(
                f"Error loading sqlite init script, found at path {self.context.init_sql_path} with exception {e}"
            )
            conn.rollback()
            conn.close()

        conn.commit()
        conn.close()

        return True

    def add_track(self, track: Track, timeout: float = 5) -> bool:
        if track.metadata.is_empty():
            print(
                f"empty metadata track passed to Database.add_track(): {track.metadata}"
            )
            return False

        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return False
        tracks_cursor = conn.cursor()
        trackmetadata_cursor = conn.cursor()

        track_id = None
        try:
            tracks_entry = (
                track.uuid_id,
                str(track.file_path),
                track.file_hash,
                track.created_at,
                track.last_updated,
            )
            tracks_sql_query = (
                "INSERT INTO tracks (uuid_id, file_path, file_hash, created_at, last_updated) "
                "VALUES (?, ?, ?, ?, ?)"
            )
            temp = tracks_cursor.execute(tracks_sql_query, tracks_entry)
            track_id = temp.lastrowid
        except Exception as e:
            print(f"Failed to insert {track} into tracks table {e}")
            conn.rollback()
            conn.close()
            return False

        try:
            trackmetadata = track.metadata
            trackmetadata_entry = (
                track_id,
                track.uuid_id,
                trackmetadata.title,
                trackmetadata.artist,
                trackmetadata.album,
                trackmetadata.album_artist,
                trackmetadata.year,
                trackmetadata.date,
                trackmetadata.genre,
                trackmetadata.track_number,
                trackmetadata.disc_number,
                trackmetadata.codec,
                trackmetadata.duration,
                trackmetadata.bitrate_kbps,
                trackmetadata.sample_rate_hz,
                trackmetadata.channels,
                trackmetadata.has_album_art,
            )

            trackmetadata_sql_query = (
                "INSERT INTO trackmetadata (track_id, uuid_id, title, artist, album, album_artist, "
                '"year", "date", genre, track_number, disc_number, codec, duration, '
                "bitrate_kbps, sample_rate_hz, channels, has_album_art) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            )

            trackmetadata_cursor.execute(trackmetadata_sql_query, trackmetadata_entry)
        except Exception as e:
            print(f"Failed to insert {track.metadata} into trackmetadata table {e}")
            conn.rollback()
            conn.close()
            return False

        try:
            conn.commit()
            conn.close()
            return True
        except Exception as e:
            print(f"Failed to commit track {track}. {e}")
            conn.rollback()
            conn.close
            return False

    def delete_track(self, uuid_id: str, timeout: float = 5) -> bool:
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return False
        tracks_cursor = conn.cursor()
        trackmetadata_cursor = conn.cursor()

        try:
            trackmetadata_cursor.execute(
                "DELETE FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
            )
        except Exception as e:
            print(f"failed to delete {uuid_id} from trackmetadata {e}")
            conn.rollback()
            conn.close()
            return False

        try:
            tracks_cursor.execute("DELETE FROM tracks WHERE uuid_id = ?", (uuid_id,))
        except Exception as e:
            print(f"failed to delete {uuid_id} from tracks. {e}")
            conn.rollback()
            conn.close()
            return False

        if trackmetadata_cursor.rowcount == 0:
            conn.rollback()
            conn.close()
            return False

        if trackmetadata_cursor.rowcount != tracks_cursor.rowcount:
            print(f"row was deleted from tracks XOR trackmetadata. uuid_id: {uuid_id}")
            conn.rollback()
            conn.close()
            return False

        try:
            conn.commit()
            conn.close()
            return True
        except Exception as e:
            print(f"Failed to commit deletion of uuid_id {uuid_id}. {e}")
            conn.rollback()
            conn.close
            return False

    # TODO: searching needs some refactor. Specifically, using dicts for the searching is bad.
    def get_tracks(
        self,
        search_parameters: List[SearchParameter] = [],
        order_parameters: List[OrderParameter] = [],
        row_filter_parameters: List[RowFilterParameter] = [],
        artist: Optional[str] = None,
        album: Optional[str] = None,
        timeout: float = 5,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Track]:
        if album is not None and artist is None:
            raise ValueError("Cannot filter by album without artist")

        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_tracks"
            )
            raise ValueError

        allowed_columns = set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS)
        search_columns = set([param.column for param in search_parameters])
        order_columns = set([order.column for order in order_parameters])
        invalid_search_columns = search_columns - allowed_columns
        invalid_order_columns = order_columns - allowed_columns

        if invalid_search_columns:
            print(
                f"columns {invalid_search_columns} are not allowed as a search parameter"
            )
            raise ValueError

        if invalid_order_columns:
            print(
                f"columns {invalid_order_columns} are not allowed as a search parameter"
            )
            raise ValueError

        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return []
        conn.row_factory = sqlite3.Row
        search_cursor = conn.cursor()

        search_query = (
            "SELECT "
            'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, tm."year", '
            'tm."date", tm.genre, tm.track_number, tm.disc_number, tm.codec, tm.duration, '
            "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, tm.has_album_art, t.file_path, "
            "t.file_hash, t.created_at, t.last_updated "
            "FROM trackmetadata AS tm "
            "JOIN tracks AS t ON "
            " tm.uuid_id = t.uuid_id"
        )
        search_clauses = []
        search_values = []

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

        if artist is not None:
            aa_clause, aa_values = artist_album_filter_clause(artist, album)
            search_clauses.append("(" + aa_clause + ")")
            search_values.extend(aa_values)

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
            rows = search_cursor.execute(search_query, tuple(search_values)).fetchall()
        except Exception as e:
            print(
                f"Failed to search database. search_parameters: {search_parameters}. Exception: {e}"
            )
            conn.close()
            return []
        finally:
            conn.close()

        tracks: List[Track] = []
        for row in rows:
            metadata = TrackMetaData(
                title=row["title"],
                artist=row["artist"],
                album=row["album"],
                album_artist=row["album_artist"],
                year=row["year"],
                date=row["date"],
                genre=row["genre"],
                track_number=row["track_number"],
                disc_number=row["disc_number"],
                codec=row["codec"],
                duration=row["duration"],
                bitrate_kbps=row["bitrate_kbps"],
                sample_rate_hz=row["sample_rate_hz"],
                channels=row["channels"],
                has_album_art=bool(row["has_album_art"]),
            )

            tracks.append(
                Track(
                    uuid_id=row["uuid_id"],
                    file_path=Path(row["file_path"]),
                    metadata=metadata,
                    file_hash=row["file_hash"],
                    created_at=row["created_at"],
                    last_updated=row["last_updated"],
                )
            )

        return tracks

    def get_tracks_count(
        self,
        search_parameters: List[SearchParameter] = [],
        order_parameters: List[OrderParameter] = [],
        row_filter_parameters: List[RowFilterParameter] = [],
        artist: Optional[str] = None,
        album: Optional[str] = None,
        timeout: float = 5,
    ) -> int | None:
        if album is not None and artist is None:
            raise ValueError("Cannot filter by album without artist")

        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return None

        search_query = (
            "SELECT COUNT(*) FROM tracks as t "
            "JOIN trackmetadata AS tm ON "
            " t.uuid_id = tm.uuid_id"
        )

        search_clauses = []
        search_values = []

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

        if artist is not None:
            aa_clause, aa_values = artist_album_filter_clause(artist, album)
            search_clauses.append("(" + aa_clause + ")")
            search_values.extend(aa_values)

        if row_filter_parameters and order_parameters:
            cursor_clause, cursor_values = filter_for_cursor(
                row_filter_parameters, order_parameters
            )
            if cursor_clause:
                search_clauses.append("(" + cursor_clause + ")")
                search_values.extend(cursor_values)

        if search_clauses:
            search_query += " WHERE " + " AND ".join(search_clauses)

        cursor = conn.cursor()
        try:
            count = int(
                cursor.execute(search_query, tuple(search_values)).fetchone()[0]
            )
        except Exception as e:
            print(f"Failed to get count from database whil executing query: {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return count

    def get_artists(
        self, limit: int = 100, offset: int = 0, timeout: float = 5
    ) -> List[str] | None:
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_artists"
            )
            raise ValueError
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return None

        conn.row_factory = sqlite3.Row

        query = (
            "WITH candidates(value, row_order) AS ( "
            " SELECT artist, rowid FROM trackmetadata "
            " WHERE (album_artist IS NULL OR album_artist IS '') "
            " AND (artist IS NOT NULL AND artist <> '') "
            " UNION ALL "
            " SELECT album_artist, rowid FROM trackmetadata "
            " WHERE album_artist IS NOT NULL AND album_artist <> '' "
            ") "
            "SELECT value, MIN(row_order) FROM candidates "
            "GROUP BY LOWER(value) "
            "ORDER BY LOWER(value) ASC "
            "LIMIT ? OFFSET ?"
        )

        try:
            cursor = conn.cursor()
            rows = cursor.execute(query, (limit, offset)).fetchall()
        except Exception as e:
            print(f"Error executing distinct artist query: {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return [str(row["value"]) for row in rows if row]

    def get_artists_count(self, timeout: float = 5) -> int | None:
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            print("Unable to connect to database")
            return None

        query = (
            "WITH candidates(value) AS ( "
            " SELECT artist FROM trackmetadata "
            " WHERE (album_artist IS NULL OR album_artist IS '') "
            " AND (artist IS NOT NULL AND artist <> '') "
            " UNION ALL "
            " SELECT album_artist FROM trackmetadata "
            " WHERE album_artist IS NOT NULL AND album_artist <> '' "
            ") "
            "SELECT COUNT(*) FROM ( "
            " SELECT value FROM candidates "
            " GROUP BY LOWER(value) "
            ") "
        )

        try:
            cursor = conn.cursor()
            artist_count = int(cursor.execute(query).fetchone()[0])
        except Exception as e:
            print(f"Unable to fetch artist and/or album artists counts. {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return artist_count

    def get_albums(
        self,
        artist: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
        order_by: str = "year",
        timeout: float = 5,
    ) -> List[str] | None:
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_albums"
            )
            raise ValueError

        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return None

        conn.row_factory = sqlite3.Row

        order_clause = (
            "ORDER BY LOWER(value) ASC"
            if order_by == "alphabetical"
            else "ORDER BY MIN(year_n) ASC"
        )

        if artist is not None:
            query = (
                "WITH candidates(value, year_n, row_order) AS ( "
                ' SELECT album, "year", rowid FROM trackmetadata '
                " WHERE artist LIKE ? "
                " AND (album IS NOT NULL AND album IS NOT '') "
                " AND (album_artist IS NULL OR album_artist IS '') "
                " UNION ALL "
                ' SELECT album, "year", rowid FROM trackmetadata '
                " WHERE album_artist LIKE ? "
                " AND (album IS NOT NULL AND album IS NOT '') "
                ") "
                "SELECT value, MIN(row_order) FROM candidates "
                "GROUP BY LOWER(value) "
                f"{order_clause} "
                "LIMIT ? OFFSET ?"
            )
            parameters = (artist, artist, limit, offset)
        else:
            query = (
                "WITH candidates(value, year_n, row_order) AS ( "
                ' SELECT album, "year", rowid FROM trackmetadata '
                " WHERE (album IS NOT NULL AND album IS NOT '') "
                ") "
                "SELECT value, MIN(row_order) FROM candidates "
                "GROUP BY LOWER(value) "
                f"{order_clause} "
                "LIMIT ? OFFSET ?"
            )
            parameters = (limit, offset)

        try:
            cursor = conn.cursor()
            album_rows = cursor.execute(query, parameters).fetchall()
        except Exception as e:
            print(f"Failed to retrieve albums: {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return [row["value"] for row in album_rows]

    def get_albums_count(
        self, artist: Optional[str] = None, timeout: float = 5
    ) -> int | None:
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            print("Unable to connect to database")
            return None

        if artist is not None:
            query = (
                "WITH candidates(value) AS ( "
                " SELECT album FROM trackmetadata "
                " WHERE artist LIKE ? "
                " AND (album IS NOT NULL AND album IS NOT '') "
                " AND (album_artist IS NULL OR album_artist IS '') "
                " UNION ALL "
                " SELECT album FROM trackmetadata "
                " WHERE album_artist LIKE ? "
                " AND (album IS NOT NULL AND album IS NOT '') "
                ") "
                "SELECT COUNT(*) FROM ("
                " SELECT value FROM candidates"
                " GROUP BY LOWER(value)"
                ")"
            )
            parameters = (artist, artist)
        else:
            query = (
                "SELECT COUNT(*) FROM ("
                " SELECT album FROM trackmetadata "
                " WHERE (album IS NOT NULL AND album IS NOT '') "
                " GROUP BY LOWER(album)"
                ")"
            )
            parameters = ()

        try:
            cursor = conn.cursor()
            album_count = int(cursor.execute(query, parameters).fetchone()[0])
        except Exception as e:
            print(f"Failed to retrieve album counts: {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return album_count


def alias_map(column: str) -> str:
    if column in ALLOWED_METADATA_COLUMNS:
        return "tm"
    else:
        return "t"


# Sort-key cursor pagination logic.
# This cursor logic is linked to the frontend's getTrackPage() / getAlbumTrackPage()
# in frontend/lib/database/database.dart — keep them in sync.
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


def artist_album_filter_clause(
    artist: str, album: Optional[str]
) -> tuple[str, List[str]]:
    artist_clause = (
        '((tm."artist" LIKE ? AND (tm."album_artist" IS NULL OR tm."album_artist" = \'\'))'
        ' OR tm."album_artist" LIKE ?)'
    )
    values = [artist, artist]

    if album is None:
        album_clause = 'tm."album" IS NULL'
    else:
        album_clause = 'tm."album" LIKE ?'
        values.append(album)

    return (artist_clause + " AND " + album_clause, values)
