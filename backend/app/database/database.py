import sqlite3
import unicodedata
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Flag, auto
from pathlib import Path
from typing import List, Literal, Optional

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

# Track tag fields a user may edit via Get Info / PATCH. Deliberately NOT
# ``ALLOWED_METADATA_COLUMNS`` — that list includes audio-derived columns
# (codec/duration/bitrate_kbps/sample_rate_hz/channels/has_album_art/
# cover_art_id) which must never be hand-edited. This is the single source of
# truth shared by ``GET /app/info`` (advertised) and ``PATCH`` (accepted).
EDITABLE_METADATA_COLUMNS = [
    "title",
    "artist",
    "album",
    "album_artist",
    "year",
    "date",
    "genre",
    "track_number",
    "disc_number",
]

ALLOWED_TRACK_COLUMNS = ["uuid_id", "created_at", "last_updated"]

ALLOWED_ALBUM_COLUMNS = ["id", "name", "artist", "artist_id", "year", "is_single_grouping"]
ALBUM_TEXT_COLUMNS = {"name", "artist"}
ALBUM_INTEGER_COLUMNS = {"id", "artist_id", "year", "is_single_grouping"}

ALLOWED_ARTIST_COLUMNS = ["id", "name"]
ARTIST_TEXT_COLUMNS = {"name"}

ALLOWED_OPERATORS = ["=", ">=", "<=", "<", ">"]


class TrackNotFound(Exception):
    """Raised when a metadata edit targets a uuid that no longer exists."""


class EmptyTrackEdit(Exception):
    """Raised when an edit would blank a track's whole identity (title, artist,
    and album all empty). Distinct from ``add_track``'s ``is_empty`` audio-field
    check — this guards the human-meaningful fields."""


class RevisionConflict(Exception):
    """Raised when an edit's ``base_revision`` no longer matches the stored
    revision — the row moved on under the editor (Option A 409)."""

    def __init__(self, uuid_id: str, base_revision: Optional[int], current_revision: int):
        self.uuid_id = uuid_id
        self.base_revision = base_revision
        self.current_revision = current_revision
        super().__init__(
            f"revision conflict on {uuid_id}: base={base_revision} "
            f"current={current_revision}"
        )


def _effective_artist(album_artist: Optional[str], artist: Optional[str]) -> Optional[str]:
    """The artist that owns a track's library identity: album_artist wins, then
    artist, else None. Shared by ``add_track`` and the metadata-edit spine so
    DB identity is computed one way everywhere."""
    if album_artist and album_artist.strip():
        return album_artist.strip()
    if artist and artist.strip():
        return artist.strip()
    return None


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
    keys = row.keys()
    return Track(
        uuid_id=row["uuid_id"],
        file_path=Path(row["file_path"]),
        metadata=metadata,
        file_hash=row["file_hash"],
        created_at=row["created_at"],
        last_updated=row["last_updated"],
        revision=row["revision"] if "revision" in keys else 0,
    )


TRACK_SELECT_COLUMNS = (
    "tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, "
    'tm.artist_id, tm.album_id, tm."year", tm."date", tm.genre, '
    "tm.track_number, tm.disc_number, tm.codec, tm.duration, "
    "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, "
    "tm.has_album_art, tm.cover_art_id, t.file_path, t.file_hash, "
    "t.created_at, t.last_updated, t.revision"
)


def _track_select_columns(*extra_columns: str) -> str:
    columns = TRACK_SELECT_COLUMNS
    if extra_columns:
        columns += ", " + ", ".join(extra_columns)
    return columns


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

    # Schema version a freshly-initialized database lands on. Keep in sync
    # with the highest version handled in ``_migrate`` and the schema in
    # ``init.sql``. The previous value of 2 left fresh DBs reporting an
    # older version than they actually had (init.sql already creates the v3
    # ``app_settings`` table), which would have made any future v3→v4
    # migration spuriously re-create existing tables.
    LATEST_SCHEMA_VERSION = 5

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
                conn.execute(f"PRAGMA user_version = {self.LATEST_SCHEMA_VERSION}")
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

            if version < 2:
                print("Migrating database to version 2: adding queue_sync_state table")
                conn.execute(
                    'CREATE TABLE IF NOT EXISTS queue_sync_state ('
                    '"session_id" TEXT NOT NULL PRIMARY KEY, '
                    '"current_index" INTEGER NOT NULL, '
                    '"quality" TEXT NOT NULL, '
                    '"track_uuids" TEXT NOT NULL, '
                    '"updated_at" REAL NOT NULL'
                    ')'
                )
                conn.execute("PRAGMA user_version = 2")

            if version < 3:
                print("Migrating database to version 3: adding app_settings table")
                conn.execute(
                    'CREATE TABLE IF NOT EXISTS app_settings ('
                    'key TEXT NOT NULL PRIMARY KEY, '
                    'value TEXT NOT NULL'
                    ')'
                )
                conn.execute("PRAGMA user_version = 3")

            if version < 4:
                print(
                    "Migrating database to version 4: adding track_tombstones table"
                )
                conn.execute(
                    'CREATE TABLE IF NOT EXISTS track_tombstones ('
                    '    "uuid_id"    TEXT PRIMARY KEY,'
                    '    "deleted_at" INTEGER NOT NULL'
                    ')'
                )
                conn.execute(
                    'CREATE INDEX IF NOT EXISTS idx_track_tombstones_deleted_at '
                    'ON track_tombstones("deleted_at")'
                )
                conn.execute("PRAGMA user_version = 4")

            if version < 5:
                print(
                    "Migrating database to version 5: adding monotonic "
                    "revisions for incremental sync"
                )
                conn.execute(
                    'CREATE TABLE IF NOT EXISTS revision_counter ('
                    '    "id"    INTEGER PRIMARY KEY CHECK ("id" = 0),'
                    '    "value" INTEGER NOT NULL'
                    ')'
                )
                conn.execute(
                    "INSERT OR IGNORE INTO revision_counter (id, value) "
                    "VALUES (0, 0)"
                )

                def _table_exists(name: str) -> bool:
                    return (
                        conn.execute(
                            "SELECT 1 FROM sqlite_master "
                            "WHERE type='table' AND name=?",
                            (name,),
                        ).fetchone()
                        is not None
                    )

                # Backfill numbers existing tracks (by last_updated) then
                # tombstones (by deleted_at) into one revision space. Exact
                # historical interleave does not matter — only that every uuid
                # gets a unique revision and a live track out-numbers any prior
                # tombstone for the same uuid.
                track_max = 0
                if _table_exists("tracks"):
                    try:
                        conn.execute(
                            'ALTER TABLE tracks ADD COLUMN "revision" '
                            "INTEGER NOT NULL DEFAULT 0"
                        )
                    except sqlite3.OperationalError:
                        pass  # Column already exists
                    conn.execute(
                        'CREATE INDEX IF NOT EXISTS idx_tracks_revision '
                        'ON tracks("revision")'
                    )
                    conn.execute(
                        "UPDATE tracks SET revision = rn FROM ("
                        "  SELECT id, ROW_NUMBER() OVER ("
                        "    ORDER BY last_updated, id) AS rn FROM tracks"
                        ") AS ordered WHERE tracks.id = ordered.id"
                    )
                    track_max = conn.execute(
                        "SELECT COALESCE(MAX(revision), 0) FROM tracks"
                    ).fetchone()[0]

                tombstone_max = track_max
                if _table_exists("track_tombstones"):
                    try:
                        conn.execute(
                            'ALTER TABLE track_tombstones ADD COLUMN "revision" '
                            "INTEGER NOT NULL DEFAULT 0"
                        )
                    except sqlite3.OperationalError:
                        pass  # Column already exists
                    conn.execute(
                        'CREATE INDEX IF NOT EXISTS idx_track_tombstones_revision '
                        'ON track_tombstones("revision")'
                    )
                    conn.execute(
                        "UPDATE track_tombstones SET revision = ? + rn FROM ("
                        "  SELECT uuid_id, ROW_NUMBER() OVER ("
                        "    ORDER BY deleted_at, uuid_id) AS rn"
                        "  FROM track_tombstones"
                        ") AS ordered "
                        "WHERE track_tombstones.uuid_id = ordered.uuid_id",
                        (track_max,),
                    )
                    tombstone_max = conn.execute(
                        "SELECT COALESCE(MAX(revision), 0) FROM track_tombstones"
                    ).fetchone()[0]

                conn.execute(
                    "UPDATE revision_counter SET value = ? WHERE id = 0",
                    (max(track_max, tombstone_max),),
                )
                conn.execute("PRAGMA user_version = 5")

    @staticmethod
    def _next_revision(conn) -> int:
        """Allocate the next monotonic revision on ``conn``'s open transaction.

        Safe under SQLite's single-writer serialization — the increment and
        read-back happen inside the caller's exclusive write transaction, so
        no two writers can observe the same value. Must be called before the
        row write that stores the returned revision."""
        conn.execute("UPDATE revision_counter SET value = value + 1 WHERE id = 0")
        return conn.execute(
            "SELECT value FROM revision_counter WHERE id = 0"
        ).fetchone()[0]

    @staticmethod
    def _bump_track_revision(conn, uuid_id: str) -> None:
        conn.execute(
            "UPDATE tracks SET revision = ?, last_updated = unixepoch() "
            "WHERE uuid_id = ?",
            (Database._next_revision(conn), uuid_id),
        )

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
        """Set cover_art_id to NULL on all trackmetadata rows referencing this cover art.

        Allocates a fresh revision per affected row so each cover-art removal
        propagates as its own change to incremental-sync clients — without
        this it would never reach a client that synced before the next "real"
        metadata edit.
        """
        with self._connection(commit=True) as conn:
            affected = conn.execute(
                "SELECT uuid_id FROM trackmetadata WHERE cover_art_id = ?",
                (cover_art_id,),
            ).fetchall()
            conn.execute(
                "UPDATE trackmetadata SET cover_art_id = NULL WHERE cover_art_id = ?",
                (cover_art_id,),
            )
            for row in affected:
                self._bump_track_revision(conn, row["uuid_id"])

    def delete_cover_art(self, cover_art_id: int) -> bool:
        try:
            with self._connection(commit=True) as conn:
                affected = conn.execute(
                    "SELECT uuid_id FROM trackmetadata WHERE cover_art_id = ?",
                    (cover_art_id,),
                ).fetchall()
                cursor = conn.execute(
                    "DELETE FROM cover_arts WHERE id = ?", (cover_art_id,)
                )
                if cursor.rowcount > 0:
                    for row in affected:
                        self._bump_track_revision(conn, row["uuid_id"])
                return cursor.rowcount > 0
        except Exception as e:
            print(f"Failed to delete cover art {cover_art_id}: {e}")
            return False

    def get_tracks_missing_cover_art(self) -> List[Track]:
        """Return tracks where has_album_art=1 AND cover_art_id IS NULL."""
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    f"SELECT {_track_select_columns()} "
                    "FROM trackmetadata AS tm "
                    "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                    "WHERE tm.has_album_art = 1 AND tm.cover_art_id IS NULL"
                ).fetchall()
                return [_row_to_track(row) for row in rows]
        except Exception as e:
            print(f"Failed to get tracks missing cover art: {e}")
            return []

    def update_track_cover_art_id(self, uuid_id: str, cover_art_id: int) -> bool:
        """Set cover_art_id for a specific track identified by uuid_id.

        Allocates a fresh revision so the frontend's incremental sync sees the
        cover-art assignment — without it, a backfill-only change would never
        appear in a ``GET /changes`` page.
        """
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ?",
                    (cover_art_id, uuid_id),
                )
                if cursor.rowcount > 0:
                    self._bump_track_revision(conn, uuid_id)
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
                effective_artist = _effective_artist(
                    metadata.album_artist, metadata.artist
                )

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

                # Clear any stale tombstone so a re-added uuid is not also
                # streamed as a delete; the fresh row's higher revision would
                # supersede it anyway, but dropping it keeps the stream clean.
                conn.execute(
                    "DELETE FROM track_tombstones WHERE uuid_id = ?",
                    (track.uuid_id,),
                )

                # Insert track with a freshly allocated monotonic revision.
                revision = self._next_revision(conn)
                track.revision = revision
                tracks_entry = (
                    track.uuid_id,
                    str(track.file_path),
                    track.file_hash,
                    track.created_at,
                    track.last_updated,
                    revision,
                )
                tracks_sql_query = (
                    "INSERT INTO tracks "
                    "(uuid_id, file_path, file_hash, created_at, last_updated, revision) "
                    "VALUES (?, ?, ?, ?, ?, ?)"
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

    @staticmethod
    def _orphan_gc_album(conn, album_id: Optional[int]) -> None:
        """Delete ``album_id`` and its FTS row iff no trackmetadata references
        it. The FTS ``'delete'`` values are derived from the album's own
        artist join, so they always match what ``_upsert_album`` inserted."""
        if album_id is None:
            return
        remaining = conn.execute(
            "SELECT COUNT(*) FROM trackmetadata WHERE album_id = ?", (album_id,)
        ).fetchone()[0]
        if remaining != 0:
            return
        row = conn.execute(
            "SELECT a.name AS album_name, ar.name AS artist_name "
            "FROM albums a JOIN artists ar ON ar.id = a.artist_id "
            "WHERE a.id = ?",
            (album_id,),
        ).fetchone()
        album_name = (row["album_name"] or "") if row else ""
        artist_name = (row["artist_name"] or "") if row else ""
        conn.execute(
            "INSERT INTO fts_albums(fts_albums, rowid, name, artist_name) "
            "VALUES('delete', ?, ?, ?)",
            (album_id, album_name, artist_name),
        )
        conn.execute("DELETE FROM albums WHERE id = ?", (album_id,))

    @staticmethod
    def _orphan_gc_artist(conn, artist_id: Optional[int]) -> None:
        """Delete ``artist_id`` and its FTS row iff no trackmetadata references
        it. Call after ``_orphan_gc_album`` — an album row references an artist."""
        if artist_id is None:
            return
        remaining = conn.execute(
            "SELECT COUNT(*) FROM trackmetadata WHERE artist_id = ?", (artist_id,)
        ).fetchone()[0]
        if remaining != 0:
            return
        row = conn.execute(
            "SELECT name FROM artists WHERE id = ?", (artist_id,)
        ).fetchone()
        artist_name = (row["name"] or "") if row else ""
        conn.execute(
            "INSERT INTO fts_artists(fts_artists, rowid, name) VALUES('delete', ?, ?)",
            (artist_id, artist_name),
        )
        conn.execute("DELETE FROM artists WHERE id = ?", (artist_id,))

    @staticmethod
    def _recompute_named_album_year(conn, album_id: Optional[int]) -> None:
        """Reset a *named* album's year to MAX over its remaining members.
        ``_upsert_album`` only ever raises an album's year, so a downward edit
        (a member lowering/clearing its year, or leaving the album) needs this.
        Single-grouping albums carry year as identity and are reconciled by the
        normal upsert path, so they are excluded."""
        if album_id is None:
            return
        conn.execute(
            'UPDATE albums SET "year" = '
            '(SELECT MAX("year") FROM trackmetadata WHERE album_id = ?) '
            "WHERE id = ? AND is_single_grouping = 0",
            (album_id, album_id),
        )

    def _update_track_metadata(self, conn, uuid_id: str, fields: dict) -> None:
        """Pure-DB metadata edit — no file I/O. ``fields`` is the validated,
        present subset of ``EDITABLE_METADATA_COLUMNS`` (an explicit ``None``
        means "clear"). Reassigns artist/album identity, reconciles orphaned
        parents + FTS, and bumps the track revision. Reused by the PATCH
        orchestration and (future) bulk edit, all inside one caller txn."""
        cur = conn.execute(
            "SELECT track_id, artist_id, album_id, title, artist, album, "
            'album_artist, "year", "date", genre, track_number, disc_number '
            "FROM trackmetadata WHERE uuid_id = ?",
            (uuid_id,),
        ).fetchone()
        if cur is None:
            raise TrackNotFound(uuid_id)

        track_db_id = cur["track_id"]
        old_artist_id = cur["artist_id"]
        old_album_id = cur["album_id"]

        # Merge present edits over current values, then NFC-normalize the
        # identity strings before they reach the LOWER()-keyed upsert
        # (otherwise canonically-equivalent spellings won't dedup).
        def pick(col):
            return fields[col] if col in fields else cur[col]

        new = {col: pick(col) for col in EDITABLE_METADATA_COLUMNS}
        for col in ("artist", "album", "album_artist"):
            if isinstance(new[col], str):
                new[col] = unicodedata.normalize("NFC", new[col])

        # Don't let an edit blank the whole track — checked on the *merged*
        # post-edit state so a partial clear (e.g. just the title) is fine as
        # long as artist or album survives.
        def _blank(v):
            return v is None or (isinstance(v, str) and not v.strip())

        if _blank(new["title"]) and _blank(new["artist"]) and _blank(new["album"]):
            raise EmptyTrackEdit(uuid_id)

        effective = _effective_artist(new["album_artist"], new["artist"])
        new_artist_id = None
        new_album_id = None
        if effective is not None:
            new_artist_id = self._upsert_artist(conn, effective)
            has_album = bool(new["album"] and new["album"].strip())
            new_album_id = self._upsert_album(
                conn,
                new["album"] if has_album else None,
                new_artist_id,
                new["year"],
                effective,
            )
        # effective is None ⇒ artist cleared; both ids stay None (an album row
        # requires a non-null artist).

        conn.execute(
            "UPDATE trackmetadata SET title = ?, artist = ?, album = ?, "
            'album_artist = ?, "year" = ?, "date" = ?, genre = ?, '
            "track_number = ?, disc_number = ?, artist_id = ?, album_id = ? "
            "WHERE uuid_id = ?",
            (
                new["title"], new["artist"], new["album"], new["album_artist"],
                new["year"], new["date"], new["genre"], new["track_number"],
                new["disc_number"], new_artist_id, new_album_id, uuid_id,
            ),
        )

        # Reconcile parents with the row already reassigned: GC the old ones if
        # now empty, then recompute year for any surviving named album whose
        # membership changed.
        if old_album_id != new_album_id:
            self._orphan_gc_album(conn, old_album_id)
        if old_artist_id != new_artist_id:
            self._orphan_gc_artist(conn, old_artist_id)
        self._recompute_named_album_year(conn, old_album_id)
        if new_album_id != old_album_id:
            self._recompute_named_album_year(conn, new_album_id)

        # Rewrite this track's own FTS row: delete old terms, insert new ones.
        old_effective = _effective_artist(cur["album_artist"], cur["artist"])
        conn.execute(
            "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
            "VALUES('delete', ?, ?, ?, ?)",
            (track_db_id, cur["title"] or "", old_effective or "", cur["album"] or ""),
        )
        new_fts_album = new["album"] if (new["album"] and new["album"].strip()) else ""
        conn.execute(
            "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) "
            "VALUES (?, ?, ?, ?)",
            (track_db_id, new["title"] or "", effective or "", new_fts_album),
        )

        self._bump_track_revision(conn, uuid_id)

    def apply_track_metadata_edit(
        self,
        uuid_id: str,
        fields: dict,
        base_revision: Optional[int],
        timeout: float = 5,
    ) -> int:
        """DB-only orchestration for a track metadata edit. Opens one write
        txn, enforces the Option-A 409 (``base_revision`` vs the stored
        revision) *before* the bump, runs the pure-DB spine, and commits.
        Returns the new revision. Raises ``TrackNotFound`` / ``RevisionConflict``;
        lets ``sqlite3.OperationalError`` ("database is locked") propagate so
        the caller can surface a retryable error rather than a silent failure."""
        with self._connection(commit=True, timeout=timeout) as conn:
            row = conn.execute(
                "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,)
            ).fetchone()
            if row is None:
                raise TrackNotFound(uuid_id)
            current_revision = row["revision"]
            if base_revision is None or base_revision != current_revision:
                raise RevisionConflict(uuid_id, base_revision, current_revision)

            self._update_track_metadata(conn, uuid_id, fields)

            new_row = conn.execute(
                "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,)
            ).fetchone()
            return new_row["revision"]

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

                # Record a tombstone before the hard delete so incremental
                # sync clients can reconcile the removal — the row is about to
                # vanish from `tracks`/`trackmetadata`, leaving the frontend no
                # other signal that it ever existed.
                conn.execute(
                    "INSERT OR REPLACE INTO track_tombstones "
                    "(uuid_id, deleted_at, revision) VALUES (?, unixepoch(), ?)",
                    (uuid_id, self._next_revision(conn)),
                )

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

                # Cleanup now-orphaned parents (album before artist — an album
                # row references an artist). Shared with the metadata-edit
                # spine so add/update/delete reconcile orphans one way.
                self._orphan_gc_album(conn, album_id)
                self._orphan_gc_artist(conn, artist_id)

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

    def get_changes(
        self, after_revision: int, limit: int, timeout: float = 5
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
        row's delete carries a higher revision and arrives on a later page."""
        try:
            with self._connection(timeout=timeout) as conn:
                latest = conn.execute(
                    "SELECT value FROM revision_counter WHERE id = 0"
                ).fetchone()[0]
                stream = conn.execute(
                    "SELECT 'upsert' AS change_type, revision, uuid_id FROM tracks "
                    "WHERE revision > ? "
                    "UNION ALL "
                    "SELECT 'delete' AS change_type, revision, uuid_id "
                    "FROM track_tombstones WHERE revision > ? "
                    "ORDER BY revision ASC LIMIT ?",
                    (after_revision, after_revision, limit),
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
                        f"WHERE t.uuid_id IN ({placeholders})",
                        tuple(upsert_uuids),
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
            print(f"Failed to get changes after revision {after_revision}: {e}")
            raise

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
                            f"SELECT {_track_select_columns('tm.track_id')} "
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

    # ── Queue sync state ─────────────────────────────────────────────────

    def upsert_queue_sync_state(
        self,
        session_id: str,
        current_index: int,
        quality: str,
        track_uuids_json: str,
        updated_at: float,
    ) -> None:
        try:
            with self._connection(commit=True) as conn:
                # Conditional upsert: a late-arriving snapshot with an older
                # updated_at must NOT clobber a newer one. INSERT OR REPLACE
                # would happily overwrite — the ON CONFLICT WHERE clause keeps
                # the existing row when the incoming updated_at is older.
                conn.execute(
                    "INSERT INTO queue_sync_state "
                    "(session_id, current_index, quality, track_uuids, updated_at) "
                    "VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT(session_id) DO UPDATE SET "
                    "current_index = excluded.current_index, "
                    "quality = excluded.quality, "
                    "track_uuids = excluded.track_uuids, "
                    "updated_at = excluded.updated_at "
                    "WHERE excluded.updated_at >= queue_sync_state.updated_at",
                    (session_id, current_index, quality, track_uuids_json, updated_at),
                )
        except Exception as e:
            print(f"Error upserting queue sync state: {e}")

    def get_queue_sync_state(self, session_id: str) -> dict | None:
        try:
            with self._connection() as conn:
                row = conn.execute(
                    "SELECT session_id, current_index, quality, track_uuids, updated_at "
                    "FROM queue_sync_state WHERE session_id = ?",
                    (session_id,),
                ).fetchone()
                if row is None:
                    return None
                return {
                    "session_id": row["session_id"],
                    "current_index": row["current_index"],
                    "quality": row["quality"],
                    "track_uuids": row["track_uuids"],
                    "updated_at": row["updated_at"],
                }
        except Exception as e:
            print(f"Error getting queue sync state: {e}")
            return None

    def delete_queue_sync_state(self, session_id: str) -> bool:
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    "DELETE FROM queue_sync_state WHERE session_id = ?",
                    (session_id,),
                )
                return cursor.rowcount > 0
        except Exception as e:
            print(f"Error deleting queue sync state: {e}")
            return False

    # ── App settings ──────────────────────────────────────────────────────

    def get_setting(self, key: str) -> str | None:
        try:
            with self._connection() as conn:
                row = conn.execute(
                    "SELECT value FROM app_settings WHERE key = ?", (key,)
                ).fetchone()
                return row[0] if row else None
        except Exception as e:
            print(f"Error reading setting {key!r}: {e}")
            return None

    def set_setting(self, key: str, value: str) -> None:
        # Raises on failure so callers can keep in-memory state consistent
        # with what is actually persisted.
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (key, value),
            )

    def get_track_tombstones(self) -> list[str]:
        """Return uuids of all hard-deleted tracks. Incremental sync streams
        tombstones by revision via ``get_changes``; this remains as a simple
        helper for ops and tests."""
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT uuid_id FROM track_tombstones"
                ).fetchall()
                return [row[0] for row in rows]
        except Exception as e:
            print(f"Error fetching track tombstones: {e}")
            return []

    def get_all_track_uuids(self) -> list[str]:
        try:
            with self._connection() as conn:
                rows = conn.execute("SELECT uuid_id FROM tracks").fetchall()
                return [row[0] for row in rows]
        except Exception as e:
            print(f"Error fetching all track UUIDs: {e}")
            return []


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
