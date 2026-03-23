import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Flag, auto
from pathlib import Path
from typing import List, Optional

from app.models.album import Album
from app.models.artist import Artist
from app.models.cover_art import CoverArt
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

# TODO: catch specific sqlite3 exceptions rather than broad Exception

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


def _row_to_track(row) -> Track:
    metadata = TrackMetaData(
        title=row["title"],
        artist=row["artist"],
        album=row["album"],
        album_artist=row["album_artist"],
        artist_id=row["artist_id"],
        album_id=row["album_id"],
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
        cover_art_id=row["cover_art_id"],
    )
    return Track(
        uuid_id=row["uuid_id"],
        file_path=Path(row["file_path"]),
        metadata=metadata,
        file_hash=row["file_hash"],
        created_at=row["created_at"],
        last_updated=row["last_updated"],
    )


class Database:
    def __init__(self, context: DatabaseContext):
        self.context = context

    @contextmanager
    def _connection(self, *, commit: bool = False, timeout: float = 5):
        conn = sqlite3.connect(self.context.database_path, timeout=timeout)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.row_factory = sqlite3.Row
            yield conn
            if commit:
                conn.commit()
        except BaseException:
            if commit:
                conn.rollback()
            raise
        finally:
            conn.close()

    def initialize(self) -> bool:
        if self.context.database_path.exists():
            print("Database already exists, running migrations")
            self._migrate()
            return True
        try:
            with open(self.context.init_sql_path, "r") as f:
                init_script = f.read()
            with self._connection(commit=True) as conn:
                conn.executescript(init_script)
                conn.execute("PRAGMA user_version = 1")
            return True
        except Exception as e:
            print(f"Error initializing database: {e}")
            return False

    def _migrate(self):
        with self._connection(commit=True) as conn:
            version = conn.execute("PRAGMA user_version").fetchone()[0]

            if version < 1:
                print("Migrating database to version 1: adding cover_arts table")
                conn.execute(
                    'CREATE TABLE IF NOT EXISTS cover_arts ('
                    '    "id" INTEGER PRIMARY KEY,'
                    '    "sha256" TEXT UNIQUE NOT NULL,'
                    '    "phash" TEXT NOT NULL,'
                    '    "phash_prefix" TEXT NOT NULL,'
                    '    "file_path" TEXT UNIQUE NOT NULL'
                    ')'
                )
                conn.execute(
                    'CREATE INDEX IF NOT EXISTS idx_cover_arts_phash_prefix ON cover_arts("phash_prefix")'
                )
                try:
                    conn.execute(
                        'ALTER TABLE trackmetadata ADD COLUMN "cover_art_id" INTEGER REFERENCES cover_arts("id")'
                    )
                except sqlite3.OperationalError:
                    pass  # Column already exists
                # Truncate any existing 4-char phash prefixes to 2 chars
                conn.execute(
                    'UPDATE cover_arts SET phash_prefix = substr(phash_prefix, 1, 2) '
                    'WHERE length(phash_prefix) > 2'
                )
                # Note: PRAGMA user_version is not transactional in SQLite,
                # but the DDL above is, so partial migration is still detectable.
                conn.execute("PRAGMA user_version = 1")

    def get_cover_art_by_id(self, cover_art_id: int) -> CoverArt | None:
        try:
            with self._connection() as conn:
                row = conn.execute(
                    "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts WHERE id = ?",
                    (cover_art_id,),
                ).fetchone()
                if row is None:
                    return None
                return CoverArt(
                    id=row["id"], sha256=row["sha256"], phash=row["phash"],
                    phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
                )
        except Exception as e:
            print(f"Failed to get cover art by id {cover_art_id}: {e}")
            return None

    def get_cover_art_by_sha256(self, sha256: str) -> CoverArt | None:
        try:
            with self._connection() as conn:
                row = conn.execute(
                    "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts WHERE sha256 = ?",
                    (sha256,),
                ).fetchone()
                if row is None:
                    return None
                return CoverArt(
                    id=row["id"], sha256=row["sha256"], phash=row["phash"],
                    phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
                )
        except Exception as e:
            print(f"Failed to get cover art by sha256: {e}")
            return None

    def get_cover_arts_by_phash_prefix(self, prefix: str) -> list[CoverArt]:
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts WHERE phash_prefix = ?",
                    (prefix,),
                ).fetchall()
                return [
                    CoverArt(
                        id=row["id"], sha256=row["sha256"], phash=row["phash"],
                        phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
                    )
                    for row in rows
                ]
        except Exception as e:
            print(f"Failed to get cover arts by phash prefix: {e}")
            return []

    def insert_cover_art(self, sha256: str, phash: str, phash_prefix: str, file_path: str) -> int:
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    'INSERT INTO cover_arts (sha256, phash, phash_prefix, file_path) VALUES (?, ?, ?, ?)',
                    (sha256, phash, phash_prefix, file_path),
                )
                return cursor.lastrowid  # type: ignore[return-value]
        except Exception as e:
            print(f"Error inserting cover art: {e}")
            raise

    def clear_cover_art_references(self, cover_art_id: int) -> None:
        """Set cover_art_id to NULL on all trackmetadata rows referencing this cover art."""
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE trackmetadata SET cover_art_id = NULL WHERE cover_art_id = ?",
                (cover_art_id,),
            )

    def delete_cover_art(self, cover_art_id: int) -> bool:
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    "DELETE FROM cover_arts WHERE id = ?", (cover_art_id,)
                )
                return cursor.rowcount > 0
        except Exception as e:
            print(f"Failed to delete cover art {cover_art_id}: {e}")
            return False

    def get_tracks_missing_cover_art(self) -> List[Track]:
        """Return tracks where has_album_art=1 AND cover_art_id IS NULL."""
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT "
                    'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
                    'tm.artist_id, tm.album_id, tm."year", '
                    'tm."date", tm.genre, tm.track_number, tm.disc_number, tm.codec, tm.duration, '
                    "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, tm.has_album_art, tm.cover_art_id, t.file_path, "
                    "t.file_hash, t.created_at, t.last_updated "
                    "FROM trackmetadata AS tm "
                    "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                    "WHERE tm.has_album_art = 1 AND tm.cover_art_id IS NULL"
                ).fetchall()
                return [_row_to_track(row) for row in rows]
        except Exception as e:
            print(f"Failed to get tracks missing cover art: {e}")
            return []

    def update_track_cover_art_id(self, uuid_id: str, cover_art_id: int) -> bool:
        """Set cover_art_id for a specific track identified by uuid_id."""
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ?",
                    (cover_art_id, uuid_id),
                )
                return cursor.rowcount > 0
        except Exception as e:
            print(f"Failed to update cover_art_id for track {uuid_id}: {e}")
            return False

    def add_track(self, track: Track, timeout: float = 5) -> bool:
        if track.metadata.is_empty():
            print(
                f"empty metadata track passed to Database.add_track(): {track.metadata}"
            )
            return False

        try:
            with self._connection(commit=True, timeout=timeout) as conn:
                metadata = track.metadata

                # Determine effective artist: album_artist takes priority
                effective_artist = None
                if metadata.album_artist and metadata.album_artist.strip():
                    effective_artist = metadata.album_artist.strip()
                elif metadata.artist and metadata.artist.strip():
                    effective_artist = metadata.artist.strip()

                artist_id = None
                if effective_artist:
                    artist_id = self._upsert_artist(conn, effective_artist)

                # Determine album type
                album_name = metadata.album
                has_album = album_name is not None and album_name.strip() != ""
                album_id = None

                if artist_id is not None and effective_artist is not None:
                    album_id = self._upsert_album(
                        conn, album_name if has_album else None,
                        artist_id, metadata.year, effective_artist,
                    )

                # Insert track
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
                temp = conn.cursor().execute(tracks_sql_query, tracks_entry)
                track_db_id = temp.lastrowid

                # Insert trackmetadata
                trackmetadata_entry = (
                    track_db_id,
                    track.uuid_id,
                    metadata.title,
                    metadata.artist,
                    metadata.album,
                    metadata.album_artist,
                    artist_id,
                    album_id,
                    metadata.year,
                    metadata.date,
                    metadata.genre,
                    metadata.track_number,
                    metadata.disc_number,
                    metadata.codec,
                    metadata.duration,
                    metadata.bitrate_kbps,
                    metadata.sample_rate_hz,
                    metadata.channels,
                    metadata.has_album_art,
                    metadata.cover_art_id,
                )
                trackmetadata_sql_query = (
                    "INSERT INTO trackmetadata (track_id, uuid_id, title, artist, album, album_artist, "
                    'artist_id, album_id, "year", "date", genre, track_number, disc_number, codec, duration, '
                    "bitrate_kbps, sample_rate_hz, channels, has_album_art, cover_art_id) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                )
                conn.cursor().execute(trackmetadata_sql_query, trackmetadata_entry)

                # Insert into FTS for tracks
                fts_title = metadata.title or ""
                fts_artist = effective_artist or ""
                fts_album = album_name if has_album else ""
                conn.execute(
                    "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) VALUES (?, ?, ?, ?)",
                    (track_db_id, fts_title, fts_artist, fts_album),
                )

            return True
        except Exception as e:
            print(f"Failed to add track {track}. {e}")
            return False

    def _upsert_artist(self, conn, effective_artist: str) -> int:
        conn.execute(
            'INSERT OR IGNORE INTO artists ("name") VALUES (?)',
            (effective_artist,),
        )
        was_new_artist = conn.execute("SELECT changes()").fetchone()[0] > 0
        row = conn.execute(
            "SELECT id FROM artists WHERE name_lower = LOWER(?)",
            (effective_artist,),
        ).fetchone()
        artist_id = row["id"]

        if was_new_artist:
            conn.execute(
                "INSERT INTO fts_artists(rowid, name) VALUES (?, ?)",
                (artist_id, effective_artist),
            )

        return artist_id

    def _upsert_album(
        self, conn, album_name: str | None, artist_id: int, year: int | None, effective_artist: str
    ) -> int:
        if album_name is not None:
            # Regular album
            conn.execute(
                'INSERT OR IGNORE INTO albums ("name", "artist_id", "year", "is_single_grouping") '
                "VALUES (?, ?, ?, 0)",
                (album_name, artist_id, year),
            )
            was_new_album = conn.execute("SELECT changes()").fetchone()[0] > 0
            # Update year if new track's year is higher
            conn.execute(
                "UPDATE albums SET year = ? "
                "WHERE name_lower = LOWER(?) AND artist_id = ? AND is_single_grouping = 0 "
                "AND (year IS NULL OR year < ?)",
                (year, album_name, artist_id, year),
            )
            row = conn.execute(
                "SELECT id FROM albums WHERE name_lower = LOWER(?) AND artist_id = ? AND is_single_grouping = 0",
                (album_name, artist_id),
            ).fetchone()
            album_id = row["id"]

            if was_new_album:
                conn.execute(
                    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                    (album_id, album_name, effective_artist),
                )
        else:
            # Single grouping
            conn.execute(
                'INSERT OR IGNORE INTO albums ("name", "artist_id", "year", "is_single_grouping") '
                "VALUES (NULL, ?, ?, 1)",
                (artist_id, year),
            )
            was_new_album = conn.execute("SELECT changes()").fetchone()[0] > 0
            row = conn.execute(
                "SELECT id FROM albums WHERE artist_id = ? AND COALESCE(year, -1) = COALESCE(?, -1) AND is_single_grouping = 1",
                (artist_id, year),
            ).fetchone()
            album_id = row["id"]

            if was_new_album:
                conn.execute(
                    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                    (album_id, "", effective_artist),
                )

        return album_id

    def delete_track(self, uuid_id: str, timeout: float = 5) -> bool:
        try:
            with self._connection(commit=True, timeout=timeout) as conn:
                # Fetch metadata before deletion for FTS cleanup
                meta_row = conn.execute(
                    "SELECT tm.track_id, tm.artist_id, tm.album_id, tm.title, "
                    "tm.artist, tm.album, tm.album_artist "
                    "FROM trackmetadata tm WHERE tm.uuid_id = ?",
                    (uuid_id,),
                ).fetchone()

                if meta_row is None:
                    raise ValueError("No rows deleted")

                track_db_id = meta_row["track_id"]
                artist_id = meta_row["artist_id"]
                album_id = meta_row["album_id"]
                fts_title = meta_row["title"] or ""

                # Determine effective artist and album for FTS delete
                effective_artist = ""
                if meta_row["album_artist"] and meta_row["album_artist"].strip():
                    effective_artist = meta_row["album_artist"].strip()
                elif meta_row["artist"] and meta_row["artist"].strip():
                    effective_artist = meta_row["artist"].strip()

                fts_album = meta_row["album"] or ""

                # Delete trackmetadata and tracks
                conn.execute(
                    "DELETE FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
                )
                conn.execute("DELETE FROM tracks WHERE uuid_id = ?", (uuid_id,))

                # Delete from FTS for tracks
                conn.execute(
                    "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
                    "VALUES('delete', ?, ?, ?, ?)",
                    (track_db_id, fts_title, effective_artist, fts_album),
                )

                # Cleanup orphaned album
                if album_id is not None:
                    remaining = conn.execute(
                        "SELECT COUNT(*) FROM trackmetadata WHERE album_id = ?",
                        (album_id,),
                    ).fetchone()[0]
                    if remaining == 0:
                        album_row = conn.execute(
                            "SELECT name FROM albums WHERE id = ?", (album_id,)
                        ).fetchone()
                        album_name_for_fts = album_row["name"] or "" if album_row else ""
                        conn.execute(
                            "INSERT INTO fts_albums(fts_albums, rowid, name, artist_name) "
                            "VALUES('delete', ?, ?, ?)",
                            (album_id, album_name_for_fts, effective_artist),
                        )
                        conn.execute("DELETE FROM albums WHERE id = ?", (album_id,))

                # Cleanup orphaned artist
                if artist_id is not None:
                    remaining = conn.execute(
                        "SELECT COUNT(*) FROM trackmetadata WHERE artist_id = ?",
                        (artist_id,),
                    ).fetchone()[0]
                    if remaining == 0:
                        artist_row = conn.execute(
                            "SELECT name FROM artists WHERE id = ?", (artist_id,)
                        ).fetchone()
                        artist_name_for_fts = artist_row["name"] if artist_row else ""
                        conn.execute(
                            "INSERT INTO fts_artists(fts_artists, rowid, name) "
                            "VALUES('delete', ?, ?)",
                            (artist_id, artist_name_for_fts),
                        )
                        conn.execute(
                            "DELETE FROM artists WHERE id = ?", (artist_id,)
                        )

            return True
        except Exception as e:
            print(f"Failed to delete track {uuid_id}. {e}")
            return False

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

        search_query = (
            "SELECT "
            'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
            'tm.artist_id, tm.album_id, tm."year", '
            'tm."date", tm.genre, tm.track_number, tm.disc_number, tm.codec, tm.duration, '
            "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, tm.has_album_art, tm.cover_art_id, t.file_path, "
            "t.file_hash, t.created_at, t.last_updated "
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
            print(
                f"Failed to search database. search_parameters: {search_parameters}. Exception: {e}"
            )
            return []

        tracks: List[Track] = [_row_to_track(row) for row in rows]

        return tracks

    def get_tracks_count(
        self,
        search_parameters: List[SearchParameter] | None = None,
        order_parameters: List[OrderParameter] | None = None,
        row_filter_parameters: List[RowFilterParameter] | None = None,
        artist_id: Optional[int] = None,
        album_id: Optional[int] = None,
        timeout: float = 5,
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
            print(f"Failed to get count from database while executing query: {e}")
            return None

    def get_artists(
        self,
        order_parameters: List[ArtistOrderParameter] | None = None,
        row_filter_parameters: List[ArtistRowFilterParameter] | None = None,
        limit: int = 100,
        offset: int = 0,
        timeout: float = 5,
    ) -> List[Artist] | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_artists"
            )
            raise ValueError
        parameters: list = []

        query = "SELECT id, name FROM artists "

        # Cursor filter
        cursor_clause, cursor_values = filter_for_artist_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            query += f"WHERE {cursor_clause} "
            parameters.extend(cursor_values)

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
            print(f"Error executing artist query: {e}")
            return None

    def get_artists_count(
        self,
        order_parameters: List[ArtistOrderParameter] | None = None,
        row_filter_parameters: List[ArtistRowFilterParameter] | None = None,
        timeout: float = 5,
    ) -> int | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        parameters: list = []

        query = "SELECT COUNT(*) FROM artists "

        cursor_clause, cursor_values = filter_for_artist_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            query += f"WHERE {cursor_clause} "
            parameters.extend(cursor_values)

        try:
            with self._connection(timeout=timeout) as conn:
                artist_count = int(
                    conn.cursor().execute(query, tuple(parameters)).fetchone()[0]
                )
            return artist_count
        except Exception as e:
            print(f"Unable to fetch artist counts. {e}")
            return None

    def get_albums(
        self,
        artist_id: Optional[int] = None,
        order_parameters: List[AlbumOrderParameter] | None = None,
        row_filter_parameters: List[AlbumRowFilterParameter] | None = None,
        limit: int = 100,
        offset: int = 0,
        timeout: float = 5,
    ) -> List[Album] | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_albums"
            )
            raise ValueError

        parameters: list = []

        query = (
            "SELECT a.id, a.name, ar.name AS artist, a.artist_id, "
            'a."year", a.is_single_grouping '
            "FROM albums a "
            "JOIN artists ar ON a.artist_id = ar.id"
        )

        where_clauses: list[str] = []

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
            print(f"Failed to retrieve albums: {e}")
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

        where_clauses: list[str] = []

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
            print(f"Failed to retrieve album counts: {e}")
            return None

    def get_search_results(
        self,
        query: str,
        return_types: SearchEntityType = SearchEntityType.TRACKS | SearchEntityType.ARTISTS | SearchEntityType.ALBUMS,
        limit_per_type: int = 10,
        timeout: float = 5,
    ) -> SearchResults:
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
                        "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH ? ORDER BY rank LIMIT ?",
                        (fts_query, limit_per_type),
                    ).fetchall()
                    if track_rows:
                        track_ids = [r["rowid"] for r in track_rows]
                        placeholders = ", ".join("?" for _ in track_ids)
                        full_rows = conn.execute(
                            "SELECT "
                            'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
                            'tm.artist_id, tm.album_id, tm."year", '
                            'tm."date", tm.genre, tm.track_number, tm.disc_number, tm.codec, tm.duration, '
                            "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, tm.has_album_art, tm.cover_art_id, t.file_path, "
                            "t.file_hash, t.created_at, t.last_updated, tm.track_id "
                            "FROM trackmetadata AS tm "
                            "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                            f"WHERE tm.track_id IN ({placeholders})",
                            tuple(track_ids),
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
                        "SELECT rowid FROM fts_artists WHERE fts_artists MATCH ? ORDER BY rank LIMIT ?",
                        (fts_query, limit_per_type),
                    ).fetchall()
                    if artist_rows:
                        artist_ids = [r["rowid"] for r in artist_rows]
                        placeholders = ", ".join("?" for _ in artist_ids)
                        full_rows = conn.execute(
                            f"SELECT id, name FROM artists WHERE id IN ({placeholders})",
                            tuple(artist_ids),
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
                        "SELECT rowid FROM fts_albums WHERE fts_albums MATCH ? ORDER BY rank LIMIT ?",
                        (fts_query, limit_per_type),
                    ).fetchall()
                    if album_rows:
                        album_ids = [r["rowid"] for r in album_rows]
                        placeholders = ", ".join("?" for _ in album_ids)
                        full_rows = conn.execute(
                            "SELECT a.id, a.name, ar.name AS artist, a.artist_id, "
                            'a."year", a.is_single_grouping '
                            "FROM albums a "
                            "JOIN artists ar ON a.artist_id = ar.id "
                            f"WHERE a.id IN ({placeholders})",
                            tuple(album_ids),
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
            print(f"Search failed: {e}")

        return SearchResults(
            tracks=result_tracks, artists=result_artists, albums=result_albums
        )


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
