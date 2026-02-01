from __future__ import annotations
from curses import meta
from pydantic import BaseModel
from pathlib import Path
from .track import Track
from .track_meta_data import TrackMetaData

class ClientTrack(BaseModel):
    uuid_id: str
    metadata: TrackMetaData
    created_at: int
    last_updated: int

    @classmethod
    def from_track(cls, track: Track) -> ClientTrack:
        return cls(
            uuid_id=track.uuid_id,
            metadata=track.metadata,
            created_at=track.created_at,
            last_updated=track.last_updated
        )