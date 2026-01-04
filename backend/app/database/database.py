from app.models.track import Track
from pathlib import Path
from typing import List
import sqlite3
from dataclasses import dataclass

ALLOWED_COLUMNS = [
    "track_id",
    "uuid_id",
    "title",
    "artists",
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
    "has_album_art"
]

@dataclass(frozen = True)
class DatabaseContext:
    database_path : Path

class Database:
    def __init__(self, context: DatabaseContext):
        pass
    def initialize(self) -> bool:
        pass

    def add_track(self, track: Track, timeout: int) -> bool:
        pass

    def delete_track(self, uuid_id: str) -> bool:
        pass

    def get_tracks(self, search_parameters: dict) -> List[Track]:
        pass
