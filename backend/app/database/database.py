import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

# TODO: refactor try blocks to not be so atomic
# TODO: actually catch real sqlite excpetions from the try blocks
# TODO: use finally for the try blocks
# TODO: do not let connect_to_database return None. raising and expection is probably fine, since consumers of the function should be try catching

ALLOWED_METADATA_COLUMNS = [
    "uuid_id",
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

ALLOWED_TRACK_COLUMNS = ["created_at", "last_updated"]


@dataclass(frozen=True)
class DatabaseContext:
    database_path: Path
    init_sql_path: Path


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
        search_parameters: dict[str, Any] = {},
        order_parameters: dict[str, str] = {},
        timeout: float = 5,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Track]:
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_tracks"
            )
            raise ValueError
        allowed_columns = set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS)
        search_columns = set(search_parameters.keys())
        order_columns = set(order_parameters.keys())
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

        # Used so that created_at and last_updated are searched/ordered correctly
        def alias_map(column: str) -> tuple[str, str]:
            if column in ALLOWED_METADATA_COLUMNS:
                return "tm", "="
            else:
                return "t", ">"

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

        for key, value in search_parameters.items():
            alias, operator = alias_map(key)
            if value is None:
                search_clauses.append(f'{alias}."{key}" IS NULL')
            else:
                search_clauses.append(f'{alias}."{key}" {operator} ?')
                search_values.append(value)

        if search_clauses:
            search_query += " WHERE " + " AND ".join(search_clauses)

        order_clauses = []

        for key, value in order_parameters.items():
            alias, _ = alias_map(key)
            value = value.strip().upper()
            if value not in ["ASC", "DESC"]:
                print(f"{key} has a non allowed ordering: {value}, applying ASC")
            else:
                order_clauses.append(f'{alias}."{key}" {value.upper()}')

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

    def get_tracks_count(self, timeout: float = 5) -> int | None:
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            return None

        search_query = "SELECT COUNT(*) FROM tracks"
        cursor = conn.cursor()
        try:
            cursor.execute(search_query)
        except Exception as e:
            print(f"Failed to get count from database whil executing query: {e}")
            conn.close()
            return None

        row = cursor.fetchone()
        count = row[0]
        conn.close()
        return int(count)

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

        artist_query = (
            "SELECT DISTINCT artist FROM trackmetadata "
            "WHERE (album_artist IS NULL OR album_artist IS '') "
            "AND (artist IS NOT NULL AND artist IS NOT '') "
            "ORDER BY artist ASC "
            "LIMIT ? OFFSET ?"
        )
        artist_count_query = (
            "SELECT COUNT(DISTINCT artist) FROM trackmetadata "
            "WHERE (album_artist IS NULL OR album_artist IS '') "
            "AND (artist IS NOT NULL AND artist IS NOT '') "
        )

        artist_cursor = conn.cursor()
        artist_count_cursor = conn.cursor()

        try:
            limit_offset_tupple = (limit, offset)
            artist_rows = artist_cursor.execute(
                artist_query, limit_offset_tupple
            ).fetchall()
            artist_count = int(
                artist_count_cursor.execute(artist_count_query).fetchone()[0]
            )
        except Exception as e:
            print(f"Error executing distinct artist query: {e}")
            conn.close()
            return None

        found_artists = []

        for row in artist_rows:
            artist = row["artist"]
            artist_s = str(artist)
            found_artists.append(artist_s)

        remaining_limit = limit - len(artist_rows)
        new_offset = offset - artist_count

        if remaining_limit <= 0:
            return found_artists

        if new_offset < 0:
            new_offset = 0

        album_artist_query = (
            "SELECT DISTINCT album_artist FROM trackmetadata "
            "WHERE album_artist IS NOT NULL AND album_artist IS NOT '' "
            "ORDER BY album_artist ASC "
            "LIMIT ? OFFSET ?"
        )
        album_artist_cursor = conn.cursor()

        new_limit_offset_tupple = (remaining_limit, new_offset)
        try:
            album_artist_rows = album_artist_cursor.execute(
                album_artist_query, new_limit_offset_tupple
            ).fetchall()
        except Exception as e:
            print(f"Error executing distinct artist query: {e}")
            conn.close()
            return None
        finally:
            conn.close()

        for row in album_artist_rows:
            album_artist = row["album_artist"]
            album_artist_s = str(album_artist)
            found_artists.append(album_artist_s)

        return found_artists

    def get_artists_count(self, timeout: float = 5) -> int | None:
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            print("Unable to connect to database")
            return None

        artist_count_query = (
            "SELECT COUNT(DISTINCT artist) FROM trackmetadata "
            "WHERE (album_artist IS NULL OR album_artist IS '') "
            "AND (artist IS NOT NULL AND artist IS NOT '') "
        )

        album_artist_count_query = (
            "SELECT COUNT(DISTINCT album_artist) FROM trackmetadata "
            "WHERE album_artist IS NOT NULL AND album_artist IS NOT ''"
        )

        artist_cursor = conn.cursor()
        album_artist_cursor = conn.cursor()

        try:
            artist_count = int(artist_cursor.execute(artist_count_query).fetchone()[0])
            artist_album_count = int(
                album_artist_cursor.execute(album_artist_count_query).fetchone()[0]
            )
        except Exception as e:
            print(f"Unable to fetch artist and/or album artists counts. {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return artist_count + artist_album_count

    def get_artist_albums(
        self, artist: str, limit: int = 100, offset: int = 0, timeout: float = 5
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

        artist_query = (
            "SELECT DISTINCT album FROM trackmetadata "
            "WHERE artist = ? "
            "AND (album IS NOT NULL AND album IS NOT '') "
            "AND (album_artist IS NULL OR album_artist IS '') "
            "LIMIT ? OFFSET ?"
        )

        artist_params = (artist, limit, offset)

        artist_count_query = (
            "SELECT COUNT(DISTINCT album) FROM trackmetadata "
            "WHERE artist = ? "
            "AND (album IS NOT NULL AND album IS NOT '') "
            "AND (album_artist IS NULL OR album_artist IS '')"
        )

        try:
            artist_cursor = conn.cursor()
            count_cursor = conn.cursor()
            artist_rows = artist_cursor.execute(artist_query, artist_params).fetchall()
            artist_count = int(
                count_cursor.execute(artist_count_query, (artist,)).fetchone()[0]
            )
        except Exception as e:
            print(f"Failed to retrieve artists albums: {e}")
            conn.close()
            return None

        albums: List[str] = [str(row["album"]) for row in artist_rows]

        remaining_limit = limit - len(albums)
        new_offset = offset - artist_count

        if remaining_limit <= 0:
            return albums

        if new_offset < 0:
            new_offset = 0

        album_artist_query = (
            "SELECT DISTINCT album FROM trackmetadata "
            "WHERE album_artist = ? "
            "AND (album IS NOT NULL AND album IS NOT '') "
            "LIMIT ? OFFSET ?"
        )
        album_artist_params = (artist, remaining_limit, new_offset)

        try:
            album_artist_cursor = conn.cursor()
            album_artist_rows = album_artist_cursor.execute(
                album_artist_query, album_artist_params
            ).fetchall()
        except Exception as e:
            print(f"Failed to retrieve album artist albums: {e}")
            return None
        finally:
            conn.close()

        return albums + [str(row["album"]) for row in album_artist_rows]

    def get_artist_albums_count(self, artist: str, timeout: float = 5) -> int | None:
        conn = self.connect_to_database(timeout=timeout)
        if not conn:
            print("Unable to connect to database")
            return None

        artist_count_query = (
            "SELECT COUNT(DISTINCT album) FROM trackmetadata "
            "WHERE artist = ? "
            "AND (album IS NOT NULL AND album IS NOT '') "
            "AND (album_artist IS NULL OR album_artist IS '')"
        )

        album_artist_count_query = (
            "SELECT COUNT(DISTINCT album) FROM trackmetadata "
            "WHERE album_artist = ? "
            "AND (album IS NOT NULL AND album IS NOT '')"
        )

        artist_cursor = conn.cursor()
        album_artist_cursor = conn.cursor()
        artist_tupple = (artist,)

        try:
            artist_count = int(
                artist_cursor.execute(artist_count_query, artist_tupple).fetchone()[0]
            )
            album_artist_count = int(
                album_artist_cursor.execute(
                    album_artist_count_query, artist_tupple
                ).fetchone()[0]
            )
        except Exception as e:
            print(f"Failed to retrive album counts for {artist}: {e}")
            conn.close()
            return None
        finally:
            conn.close()

        return artist_count + album_artist_count
