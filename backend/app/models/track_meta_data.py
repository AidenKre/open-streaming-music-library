from pydantic import BaseModel
from pathlib import Path
import subprocess

class TrackMetaData(BaseModel):
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    album_artist: str | None = None
    year: int | None = None
    date: str | None = None

    genre: str | None = None
    track_number: int | None = None
    disc_number: int | None = None

    codec: str | None = None
    duration: float = 0.0
    bitrate_kbps: float = 0.0
    sample_rate_hz: int = 0
    channels: int = 0

    has_album_art: bool = False

    def is_empty(self) -> bool:
        return (
            self.codec == None
            and self.duration == 0.0
            and self.bitrate_kbps == 0.0
            and self.sample_rate_hz == 0
            and self.channels == 0
        )