from pydantic import BaseModel

# TODO: add comment field to TrackMetaData. This would also mean having to implement
# parsing for it in metadata.py and supporting it in the database (update schema, etc.)

class TrackMetaData(BaseModel):
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    album_artist: str | None = None
    artist_id: int | None = None
    album_id: int | None = None
    year: int | None = None
    date: str | None = None

    genre: str | None = None
    track_number: int | None = None
    disc_number: int | None = None

    codec: str | None = None
    duration: float | None = None
    # None = unknown (ffprobe reported no bitrate); 0.0 is a real reading.
    bitrate_kbps: float | None = None
    sample_rate_hz: int | None = None
    channels: int | None = None

    has_album_art: bool = False
    cover_art_id: int | None = None

    def is_empty(self) -> bool:
        return (
            self.codec is None
            and self.duration is None
            and self.bitrate_kbps is None
            and self.sample_rate_hz is None
            and self.channels is None
        )
