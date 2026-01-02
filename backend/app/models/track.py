from time import timezone
from pydantic import BaseModel
from pathlib import Path
from .track_meta_data import TrackMetaData
from datetime import UTC, datetime
import uuid

class Track(BaseModel):
    uuid_id: str = str(uuid.uuid4())
    file_path: Path
    metadata: TrackMetaData
    file_hash: str | None = None
    created_at: int = int(datetime.now(UTC).timestamp())
    last_updated: int = int(datetime.now(UTC).timestamp())