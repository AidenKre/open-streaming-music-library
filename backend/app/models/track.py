from typing import Any
from pydantic import BaseModel, Field
from pathlib import Path
from .track_meta_data import TrackMetaData
from datetime import UTC, datetime
import uuid

class Track(BaseModel):
    uuid_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    file_path: Path = Field(repr=False)
    metadata: TrackMetaData
    created_at: int = Field(default_factory=lambda: int(datetime.now(UTC).timestamp()))
    last_updated: int = Field(default_factory=lambda: int(datetime.now(UTC).timestamp()))
    # Assigned by the database on insert; 0 until persisted.
    revision: int = 0
    # Set from tracks.owner_id when read; None until persisted.
    owner_id: int | None = None
    # The exact layer the organizer computed for ingest, carried into add_track;
    # never serialized. None = not computed.
    audio_identity: Any = Field(default=None, exclude=True)
