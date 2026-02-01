from pathlib import Path
from typing import List
import sqlite3
from dataclasses import dataclass
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

# TODO: refactor try blocks to not be so atomic
# TODO: actually catch real sqlite excpetions from the try blocks
# TODO: use finally for the try blocks

ALLOWED_COLUMNS = [
    "track_id",
    "uuid_id",
    "title",
    "artist",
    "album",
    "album_artists",
    "year",
    "date",
    "genre",
    "track_number",
    "disc_number",
    "codec",
    "duration",
    "bitreate_kbps",
    "sample_rate_hz",
    "channels",
    "has_album_art",
]


@dataclass(frozen=True)
class DatabaseContext:
    database_path: Path
    init_sql_path: Path


class Database:
    def __init__(self, context: DatabaseContext):
        self.context = context

    def connect_to_database(self, timeout: float = 5) -> sqlite3.Connection:
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
            print(f"Failed to insert {trackmetadata} into trackmetadata table {e}")
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

    # TODO: all of searching needs to be redone.
    def get_tracks(
        self,
        search_parameters: dict,
        timeout: float = 5,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Track]:
        allowed_columns = set(ALLOWED_COLUMNS)
        input_columns = set(search_parameters.keys())
        invalid_columns = input_columns - allowed_columns
        if invalid_columns:
            print(f"columns {invalid_columns} are not allowed as a search parameter")
            return []

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
        clauses = []
        values = []

        for key, value in search_parameters.items():
            if value is None:
                clauses.append(f'tm."{key}" IS NULL')
            else:
                clauses.append(f'tm."{key}" = ?')
                values.append(value)

        if clauses:
            search_query += " WHERE " + " AND ".join(clauses)

        try:
            rows = search_cursor.execute(search_query, tuple(values)).fetchall()
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
